std = "max"
max_line_length = 120
exclude_files = {"tecs_cli/vendor", "tecs_cli/runtime"}

files["loveapp"] = {
    globals = {"love"},
}

files["spec"] = {
    std = "+busted",
    -- Specs stub io.stderr to assert that --quiet suppresses output.
    ignore = {"122/io"},
}
