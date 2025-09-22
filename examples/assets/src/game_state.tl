--- Game state names for the assets example.
--- States are created via world:createState() and managed with the state stack.
local record GameState
    LOADING: string
    PLAYING: string
end

GameState.LOADING = "loading"
GameState.PLAYING = "playing"

return GameState
