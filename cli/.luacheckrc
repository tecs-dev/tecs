std = "max"
max_line_length = 120

files["spec"] = {
    std = "+busted",
    -- Specs stub io.stderr to assert that --quiet suppresses output.
    ignore = {"122/io"},
}
