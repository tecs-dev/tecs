-- Pre-build script: build main tecs library first
local tl_files = io.popen("find ../../src -name '*.tl'"):read("*a"):gsub("\n", " ")
os.execute("cd ../.. && tl gen --root src --output-dir build " .. tl_files .. " 2>/dev/null")
