-- Type definitions for luasocket (minimal, what tecs_agent needs)

local record socket
    -- TCP socket object type
    record tcp
        settimeout: function(self: tcp, timeout: number)
        setoption: function(self: tcp, option: string, value: any): boolean, string
        bind: function(self: tcp, host: string, port: number): boolean, string
        listen: function(self: tcp, backlog: number)
        accept: function(self: tcp): tcp
        send: function(self: tcp, data: string): number, string
        receive: function(self: tcp, pattern: string): string, string
        close: function(self: tcp)

        -- Make the record callable (socket.tcp() constructor)
        metamethod __call: function(self: tcp): tcp
    end

    -- Alternative connect function
    connect: function(host: string, port: number): tcp, string
end

return socket
