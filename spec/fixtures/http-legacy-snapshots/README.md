# Legacy HTTP snapshot fixtures

These binary version 2 snapshots were generated at engine commit
`08772575b5b4128654a1d53901ccbb85786467af`, before
`tecs.io.http.DataStream` was replaced.

`request-string.bin` is the valid control. It stores a
`tecs.http.Request` whose body is a direct Lua string.

`request-file-datastream.bin` and `response-string-datastream.bin` preserve
the old nested `DataStream` wire shape. They also reproduce a defect in that
revision: loading either snapshot reconstructs the nested stream as a plain
table with no `DataStream` metatable or methods. They exist so a replacement
decoder can migrate bytes that the old encoder wrote, not as evidence that
the old implementation completed a usable round trip.

The component names remain `tecs.http.Request` and `tecs.http.Response`
because they are persisted compatibility strings.

Regenerate the fixtures from that exact commit after building it:

```sh
env \
  TECS_LUA="$PWD/out/macos-arm64-dev/lua" \
  TECS_LIB="$PWD/out/macos-arm64-dev/lib" \
  TECS_ASSETS="$PWD" \
  luajit scripts/generate-http-legacy-snapshot-fixtures.lua
```

The generator uses the revision's component serializers and binary version 2
framing. It sorts map keys because LuaJIT deliberately randomizes hash
iteration between processes; map order has no decoding meaning, but leaving it
random would make the committed fixture bytes change on regeneration.

The generated SHA-256 digests are:

```text
cd2d8f1254b6e29e16f6e90b21fef3cf9ccbd0f84e4ac7298485aeb2d5ec9fe3  request-file-datastream.bin
e9f70b03807194ceb1dcf1da842794d7f5840d607e63a068b0b3ad9edd1cc60c  request-string.bin
d71559b645a0c01d2e6adf248977647affe9403093fc2304871e6c792dceb17f  response-string-datastream.bin
```
