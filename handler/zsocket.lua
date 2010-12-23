-- Copyright (c) 2010 by Robert G. Jakabosky <bobby@neoawareness.com>
--
-- Permission is hereby granted, free of charge, to any person obtaining a copy
-- of this software and associated documentation files (the "Software"), to deal
-- in the Software without restriction, including without limitation the rights
-- to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
-- copies of the Software, and to permit persons to whom the Software is
-- furnished to do so, subject to the following conditions:
--
-- The above copyright notice and this permission notice shall be included in
-- all copies or substantial portions of the Software.
--
-- THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
-- IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
-- FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
-- AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
-- LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
-- OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
-- THE SOFTWARE.

local setmetatable = setmetatable
local print = print
local tinsert = table.insert
local tremove = table.remove

local ev = require"ev"
local zmq = require"zmq"
local z_SUBSCRIBE = zmq.SUBSCRIBE
local z_UNSUBSCRIBE = zmq.UNSUBSCRIBE
local z_IDENTITY = zmq.IDENTITY
local z_NOBLOCK = zmq.NOBLOCK
local z_RCVMORE = zmq.RCVMORE
local z_SNDMORE = zmq.SNDMORE

local mark_SNDMORE = {}

local default_send_max = 10
local default_recv_max = 10

local function worker_getopt(this, ...)
	return this.socket:getopt(...)
end

local function worker_setopt(this, ...)
	return this.socket:setopt(...)
end

local function worker_sub(this, filter)
	return this.socket:setopt(z_SUBSCRIBE, filter)
end

local function worker_unsub(this, filter)
	return this.socket:setopt(z_UNSUBSCRIBE, filter)
end

local function worker_identity(this, filter)
	return this.socket:setopt(z_IDENTITY, filter)
end

local function worker_bind(this, ...)
	return this.socket:bind(...)
end

local function worker_connect(this, ...)
	return this.socket:connect(...)
end

local function worker_close(this)
	this.is_closing = true
	if #this.send_queue == 0 or this.has_error then
		this.io_send:stop(this.loop)
		this.io_recv:stop(this.loop)
		this.io_idle:stop(this.loop)
		this.socket:close()
	end
end

local function worker_handle_error(this, loc, err)
	local worker = this.worker
	local errFunc = worker.handle_error
	this.has_error = true -- mark socket as bad.
	if errFunc then
		errFunc(this, loc, err)
	else
		print('zsocket: ' .. loc .. ': error ', err)
	end
	worker_close(this)
end

local function worker_enable_idle(this, enable)
	if enable == this.idle_enabled then return end
	this.idle_enabled = enable
	if enable then
		this.io_idle:start(this.loop)
	else
		this.io_idle:stop(this.loop)
	end
end

local function worker_send_data(this)
	local send_max = this.send_max
	local count = 0
	local s = this.socket
	local queue = this.send_queue

	repeat
		local data = queue[1]
		local flags = 0
		-- check for send more marker
		if queue[2] == mark_SNDMORE then
			flags = z_SNDMORE
		end
		local sent, err = s:send(data, flags + z_NOBLOCK)
		if not sent then
			-- got timeout error block writes.
			if err == 'timeout' then
				-- enable write IO callback.
				this.send_enabled = false
				if not this.send_blocked then
					this.io_send:start(this.loop)
					this.send_blocked = true
				end
			else
				-- socket error
				worker_handle_error(this, 'send', err)
			end
			return
		else
			-- pop sent data from queue
			tremove(queue, 1)
			-- pop send more marker
			if flags == z_SNDMORE then
				tremove(queue, 1)
			else
				-- finished whole message.
				if this._has_state then
					-- switch to receiving state.
					this.state = "RECV_ONLY"
					this.recv_enabled = true
					-- make sure idle worker is running.
					worker_enable_idle(this, true)
				end
			end
			-- check if queue is empty
			if #queue == 0 then
				this.send_enabled = false
				if this.send_blocked then
					this.io_send:stop(this.loop)
					this.send_blocked = false
				end
				-- finished queue is empty
				return
			end
		end
		count = count + 1
	until count >= send_max
	-- hit max send and still have more data to send
	this.send_enabled = true
	-- make sure idle worker is running.
	worker_enable_idle(this, true)
	return
end

local function worker_receive_data(this)
	local recv_max = this.recv_max
	local count = 0
	local s = this.socket
	local worker = this.worker
	local msg = this.recv_msg
	this.recv_msg = nil

	repeat
    local data, err = s:recv(z_NOBLOCK)
		if err then
			-- check for blocking.
			if err == 'timeout' then
				-- check if we received a partial message.
				this.recv_msg = msg
				-- recv blocked
				this.recv_enabled = false
				if not this.recv_blocked then
					this.io_recv:start(this.loop)
					this.recv_blocked = true
				end
			else
				-- socket error
				worker_handle_error(this, 'receive', err)
			end
			return
		end
		-- check for more message parts.
		local more = s:getopt(z_RCVMORE)
		if msg ~= nil then
			tinsert(msg, data)
		else
			if more == 1 then
				-- create multipart message
				msg = { data }
			else
				-- simple one part message
				msg = data
			end
		end
		if more == 0 then
			-- finished receiving whole message
			if this._has_state then
				-- switch to sending state.
				this.state = "SEND_ONLY"
			end
			-- pass read message to worker
			err = worker.handle_msg(this, msg)
			if err then
				-- worker error
				worker_handle_error(this, 'worker', err)
				return
			end
			-- we are finished if the state is stil SEND_ONLY
			if this._has_state and this.state == "SEND_ONLY" then
				this.recv_enabled = false
				return
			end
			msg = nil
		end
		count = count + 1
	until count >= recv_max

	-- save any partial message.
	this.recv_msg = msg

	-- hit max receive and we are not blocked on receiving.
	this.recv_enabled = true
	-- make sure idle worker is running.
	worker_enable_idle(this, true)

end

local function _queue_msg(queue, msg)
	local parts = #msg
	-- queue first part of message
	tinsert(queue, msg[1])
	for i=2,parts do
		-- queue more marker flag
		tinsert(queue, mark_SNDMORE)
		-- queue part of message
		tinsert(queue, msg[i])
	end
end

local function worker_send(this, data, more)
	local queue = this.send_queue
	-- check if we are in receiving-only state.
	if this._has_state and this.state == "RECV_ONLY" then
		return false, "Can't send when in receiving state."
	end
	if type(data) == 'table' then
		-- queue multipart message
		_queue_msg(queue, data)
	else
		-- queue simple data.
		tinsert(queue, data)
	end
	-- check if there is more data to send
	if more then
		-- queue a marker flag
		tinsert(queue, mark_SNDMORE)
	end
	-- try sending data now.
	if not this.send_blocked then
		worker_send_data(this)
	end
	return true, nil
end

local function worker_handle_idle(this)
	if this.recv_enabled then
		worker_receive_data(this)
	end
	if this.send_enabled then
		worker_send_data(this)
	end
	if not this.send_enabled and not this.recv_enabled then
		worker_enable_idle(this, false)
	end
end

local zsocket_mt = {
_has_state = false,
send = worker_send,
setopt = worker_setopt,
getopt = worker_getopt,
identity = worker_identity,
bind = worker_bind,
connect = worker_connect,
close = worker_close,
}
zsocket_mt.__index = zsocket_mt

local zsocket_no_send_mt = {
_has_state = false,
setopt = worker_setopt,
getopt = worker_getopt,
identity = worker_identity,
bind = worker_bind,
connect = worker_connect,
close = worker_close,
}
zsocket_no_send_mt.__index = zsocket_no_send_mt

local zsocket_sub_mt = {
_has_state = false,
setopt = worker_setopt,
getopt = worker_getopt,
sub = worker_sub,
unsub = worker_unsub,
identity = worker_identity,
bind = worker_bind,
connect = worker_connect,
close = worker_close,
}
zsocket_sub_mt.__index = zsocket_sub_mt

local zsocket_state_mt = {
_has_state = true,
send = worker_send,
setopt = worker_setopt,
getopt = worker_getopt,
identity = worker_identity,
bind = worker_bind,
connect = worker_connect,
close = worker_close,
}
zsocket_state_mt.__index = zsocket_state_mt

local type_info = {
	-- publish/subscribe workers
	[zmq.PUB]  = { mt = zsocket_mt, enable_recv = false, recv = false, send = true },
	[zmq.SUB]  = { mt = zsocket_sub_mt, enable_recv = true,  recv = true, send = false },
	-- push/pull workers
	[zmq.PUSH] = { mt = zsocket_mt, enable_recv = false, recv = false, send = true },
	[zmq.PULL] = { mt = zsocket_no_send_mt, enable_recv = true,  recv = true, send = false },
	-- two-way pair worker
	[zmq.PAIR] = { mt = zsocket_mt, enable_recv = true,  recv = true, send = true },
	-- request/response workers
	[zmq.REQ]  = { mt = zsocket_state_mt, enable_recv = false, recv = true, send = true },
	[zmq.REP]  = { mt = zsocket_state_mt, enable_recv = true,  recv = true, send = true },
	-- extended request/response workers
	[zmq.XREQ] = { mt = zsocket_mt, enable_recv = true, recv = true, send = true },
	[zmq.XREP] = { mt = zsocket_mt, enable_recv = true,  recv = true, send = true },
}

local function zsocket_wrap(s, s_type, loop, msg_cb, err_cb)
	local tinfo = type_info[s_type]
	worker = { handle_msg = msg_cb, handle_error = err_cb}
	-- create zsocket
	local this = {
		s_type = x_type,
		socket = s,
		loop = loop,
		worker = worker,
		send_enabled = false,
		recv_enabled = false,
		idle_enabled = false,
		is_closing = false,
	}
	setmetatable(this, tinfo.mt)

	local fd = s:getopt(zmq.FD)
	-- create IO watcher.
	if tinfo.send then
		local send_cb = function()
			-- try sending data.
			worker_send_data(this)
		end
		this.io_send = ev.IO.new(send_cb, fd, ev.WRITE)
		this.send_blocked = false
		this.send_queue = {}
		this.send_max = default_send_max
	end
	if tinfo.recv then
		local recv_cb = function()
			-- try receiving data.
			worker_receive_data(this)
		end
		this.io_recv = ev.IO.new(recv_cb, fd, ev.READ)
		this.recv_blocked = false
		this.recv_max = default_recv_max
		if tinfo.enable_recv then
			this.io_recv:start(loop)
		end
	end
	local idle_cb = function()
		worker_handle_idle(this)
	end
	-- create Idle watcher
	-- this is used to convert ZeroMQ FD's edge-triggered fashion to level-triggered
	this.io_idle = ev.Idle.new(idle_cb)

	return this
end

local function create(self, s_type, msg_cb, err_cb)
	-- create ZeroMQ socket
	local s, err = self.ctx:socket(s_type)
	if not s then return nil, err end

	-- wrap socket.
	return zsocket_wrap(s, s_type, self.loop, msg_cb, err_cb)
end

module'handler.zsocket'

local meta = {}
meta.__index = meta
local function no_recv_cb()
	error("Invalid this type of ZeroMQ socket shouldn't receive data.")
end
function meta:pub(err_cb)
	return create(self, zmq.PUB, no_recv_cb, err_cb)
end

function meta:sub(msg_cb, err_cb)
	return create(self, zmq.SUB, msg_cb, err_cb)
end

function meta:push(err_cb)
	return create(self, zmq.PUSH, no_recv_cb, err_cb)
end

function meta:pull(msg_cb, err_cb)
	return create(self, zmq.PULL, msg_cb, err_cb)
end

function meta:pair(msg_cb, err_cb)
	return create(self, zmq.PAIR, msg_cb, err_cb)
end

function meta:req(msg_cb, err_cb)
	return create(self, zmq.REQ, msg_cb, err_cb)
end

function meta:rep(msg_cb, err_cb)
	return create(self, zmq.REP, msg_cb, err_cb)
end

function meta:xreq(msg_cb, err_cb)
	return create(self, zmq.XREQ, msg_cb, err_cb)
end

function meta:xrep(msg_cb, err_cb)
	return create(self, zmq.XREP, msg_cb, err_cb)
end

function meta:term()
	return self.ctx:term()
end

function new(loop, io_threads)
	-- create ZeroMQ context
	local ctx, err = zmq.init(io_threads)
	if not ctx then return nil, err end

	return setmetatable({ ctx = ctx, loop = loop }, meta)
end
