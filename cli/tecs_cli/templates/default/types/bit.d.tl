local record bit
    tobit:  function(integer): integer
    tohex:  function(integer, integer): string
    bnot:   function(integer): integer
    bor:    function(...: integer): integer
    band:   function(...: integer): integer
    bxor:   function(...: integer): integer
    lshift: function(integer, integer): integer
    rshift: function(integer, integer): integer
    rol:    function(integer, integer): integer
    ror:    function(integer, integer): integer
    bswap:  function(integer): integer
end

return bit
