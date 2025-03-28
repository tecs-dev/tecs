local record libffi
    type CData = integer | number | string | { string | integer : CData } | nil
    type CType = string | CData
    type CFunction = function(...: any): CData
    type CNamespace = { string : CFunction | CData }

    load:       function(string): { string : CFunction | CData }
    load:       function<T>(string): T
    cdef:       function(string)
    new:        function(CType, i?: integer, ...: any): CData
    typeof:     function(CType, ...: any): CType
    cast:       function(CType, ...: any): CType
    metatype:   function(CType, metatable<any>): CType
    gc:         function(CData, function(CData)): CData
    sizeof:     function(CType, i?: integer): integer | nil
    alignof:    function(CType): integer
    offsetof:   function(CType, string): integer, integer | nil, integer | nil
    istype:     function(CType, any): boolean
    errno:      function(i?: integer): integer
    string:     function(CData, i?: integer): string
    copy:       function(CData, CData, integer)
    copy:       function(CData, string)
    fill:       function(CData, integer, CData)
    abi:        function(string): boolean
    os:         string
    arch:       string

    C: CNamespace

    getFFI: function(): libffi
    isFFIAvailable: function(): boolean
end

-- Cache FFI availability to avoid repeated require attempts
local ffiAvailable: boolean = nil
local cachedFFI: libffi = nil

function libffi.isFFIAvailable(): boolean
    -- Always check environment variable first to handle dynamic disabling
    if os.getenv("TECS_DISABLE_FFI") then
        ffiAvailable = false
        return false
    end

    if ffiAvailable ~= nil then
        return ffiAvailable
    end

    local success, ffi = pcall(require, "ffi" as string)
    if success and ffi and type((ffi as {string:any}).new) == "function" then
        ffiAvailable = true
        cachedFFI = ffi as libffi
        return true
    else
        ffiAvailable = false
        return false
    end
end

function libffi.getFFI(): libffi
    if libffi.isFFIAvailable() then
        return cachedFFI
    else
        error("FFI is not available - this function should only be called when FFI is available")
    end
end

return libffi