local schema <const> = require("tecs.internal.ffi.schema")

describe(
    "schema",
    function()
        describe(
            "validateFields",
            function()
                it(
                    "accepts valid fields",
                    function()
                        assert.has_no.errors(function() schema.validateFields({{"x", "float"}, {"y", "float"}}) end)
                    end
                )

                it(
                    "accepts fields with array types",
                    function()
                        assert.has_no.errors(function()
                            schema.validateFields({{"matrix", "float[16]"}, {"color", "uint8_t[4]"}})
                        end)
                    end
                )

                it(
                    "accepts underscored and mixed-case identifiers",
                    function()
                        assert.has_no.errors(function()
                            schema.validateFields({
                                {"_private", "int32_t"}, {"camelCase", "float"}, {"ALL_CAPS", "double"}
                            })
                        end)
                    end
                )

                it(
                    "errors on empty field name",
                    function()
                        assert.has_error(function()
                            schema.validateFields({{"", "float"}})
                        end, "Field #1: field name cannot be empty"
                        )
                    end
                )

                it(
                    "errors on nil field name",
                    function()
                        assert.has_error(function() schema.validateFields({{nil, "float"}} as {schema.FieldDef}) end)
                    end
                )

                it(
                    "errors on empty field type",
                    function()
                        assert.has_error(function()
                            schema.validateFields({{"x", ""}})
                        end, "Field #1: field type cannot be empty for field: x"
                        )
                    end
                )

                it(
                    "errors on nil field type",
                    function()
                        assert.has_error(function() schema.validateFields({{"x", nil}} as {schema.FieldDef}) end)
                    end
                )

                it(
                    "errors on duplicate field names",
                    function()
                        assert.has_error(function()
                            schema.validateFields({{"x", "float"}, {"y", "float"}, {"x", "int32_t"}})
                        end, "Field #3: duplicate field name: x"
                        )
                    end
                )

                it(
                    "errors on invalid C identifier starting with digit",
                    function()
                        assert.has_error(function()
                            schema.validateFields({{"3d", "float"}})
                        end, "Field #1: invalid C identifier: 3d"
                        )
                    end
                )

                it(
                    "errors on identifier with spaces",
                    function() assert.has_error(function() schema.validateFields({{"my field", "float"}}) end) end
                )

                it(
                    "errors on identifier with special characters",
                    function() assert.has_error(function() schema.validateFields({{"x-pos", "float"}}) end) end
                )

                it(
                    "errors on reserved field name",
                    function()
                        assert.has_error(function()
                            schema.validateFields({{"eventId", "int32_t"}}, {eventId = true})
                        end, "Field #1: 'eventId' is reserved and must not be specified manually"
                        )
                    end
                )

                it(
                    "allows non-reserved fields when reserved set is provided",
                    function()
                        assert.has_no.errors(function()
                            schema.validateFields({{"x", "float"}, {"y", "float"}}, {eventId = true})
                        end)
                    end
                )

                it(
                    "supports multiple reserved fields",
                    function()
                        assert.has_error(function()
                            schema.validateFields({{"typeId", "int32_t"}}, {eventId = true, typeId = true})
                        end, "Field #1: 'typeId' is reserved and must not be specified manually"
                        )
                    end
                )

                it(
                    "includes field index in error messages",
                    function()
                        assert.has_error(function()
                            schema.validateFields({{"a", "float"}, {"b", "float"}, {"", "int32_t"}})
                        end, "Field #3: field name cannot be empty"
                        )
                    end
                )

                it(
                    "accepts empty field list",
                    function() assert.has_no.errors(function() schema.validateFields({}) end) end
                )
            end
        )
    end
)
