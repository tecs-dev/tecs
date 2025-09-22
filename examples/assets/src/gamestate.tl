--- Game state names for the assets example (legacy file, prefer game_state.tl).
local record GameState
    LOADING: string
    PLAYING: string
end

GameState.LOADING = "loading"
GameState.PLAYING = "playing"

return GameState
