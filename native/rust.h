/* Rust-owned native services exposed through a C ABI.
 *
 * LuaJIT binds this header, so declarations stay within the C subset its FFI
 * parser accepts. Allocations are opaque and are always released by the Rust
 * function paired with the one that created them.
 */

#ifndef TECS_RUST_H
#define TECS_RUST_H

#include <stddef.h>
#include <stdint.h>

typedef struct TecsImage TecsImage;
typedef struct TecsBytes TecsBytes;

const char *tecsRustError(void);

TecsBytes *tecsCliHelp(void);

TecsImage *tecsImageDecode(const uint8_t *bytes, size_t length);
const uint8_t *tecsImagePixels(const TecsImage *image);
uint32_t tecsImageWidth(const TecsImage *image);
uint32_t tecsImageHeight(const TecsImage *image);
void tecsImageDestroy(TecsImage *image);

TecsBytes *tecsImageEncodePngRgbx(const uint8_t *pixels, size_t length, uint32_t width, uint32_t height, size_t pitch);
const uint8_t *tecsBytesData(const TecsBytes *bytes);
size_t tecsBytesLength(const TecsBytes *bytes);
void tecsBytesDestroy(TecsBytes *bytes);

#endif
