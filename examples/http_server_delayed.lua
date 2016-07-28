-- Copyright (c) 2011 by Robert G. Jakabosky <bobby@neoawareness.com>
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

local handler = require'handler'
handler.init{ backend = arg[1] or 'llnet_ev' }
local poll = handler.get_poller()

local httpserver = require'handler.http.server'

--this will return text every second but will not block.
--if nothing has to be send, an empty string should be 
--returned (not nil!)
local function delayedsource()
	local lasttime=0;
	local cnt=0;
	
	return function()
		local ctime = os.time();
		
		if cnt >= 10 then --10 times answered, returning nil
			return nil
		end
		
		if ctime ~= lasttime then
			cnt=cnt+1;
			lasttime=ctime;
			return "Answer Nr. " .. cnt .. "<br>\r\n"
		else
			return "","Blocking"
		end
	end
end

local function delay_pump(src, snk, delay)
	local chunk, src_err = src()
	if chunk == "" and src_err == 'Blocking' then
		-- create timer watcher
		local timer = poll:create_timer({
		on_timer = function()
			delay_pump(src, snk, delay)
		end,
		}, delay or 1.0, 0.0)
		timer:start()
	else
		local ret, snk_err = snk(chunk, src_err)
		if not ret then return nil, snk_err end
		if chunk then
			return delay_pump(src, snk, delay)
		end
	end
	return true
end

local function on_request(server, req, resp)
	resp:set_header('Content-Type', 'text/plain')
		
	resp.stream_body = true
	--resp:set_body(delayedsource())
	resp.on_error = function(resp, req, err)
		print('error sending http response:', err)
	end
	resp:send(200)
	delay_pump(delayedsource(), resp:sink(), 1.0)
end

local server = httpserver.new({
	-- set HTTP Server's "name/version" string.
	name = string.format("Test-HTTPServer/%f", math.pi),
	-- new request callback.
	on_request = on_request,
	-- timeouts
	request_head_timeout = 1.0,
	request_body_timeout = 1.0,
	write_timeout = 1.0,
	keep_alive_timeout = 1.0,
	max_keep_alive_requests = 10,
})

for i=1,#arg do
	print("HTTP server listen on:", arg[i])
	server:listen_uri(arg[i])
end

if #arg < 1 then
	local default_uri = 'tcp://127.0.0.1:1080/'
	print("HTTP server listen on default port:", default_uri)
	server:listen_uri(default_uri)
end

handler.run()

