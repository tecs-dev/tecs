//! SHA-256 hashing across the C ABI.

use std::ffi::c_char;
use std::slice;

use sha2::{Digest, Sha256};

const DIGEST_LENGTH: usize = 32;
const TEXT_LENGTH: usize = DIGEST_LENGTH * 2;
const HEX: &[u8; 16] = b"0123456789abcdef";

/// Computes SHA-256 and writes 64 lowercase hexadecimal characters and a NUL.
///
/// A null input represents the empty string only when `length` is zero.
/// Returns false without writing when either pointer is invalid.
///
/// # Safety
///
/// A non-null `bytes` must address `length` readable bytes. `output` must be
/// null or address at least 65 writable bytes.
#[no_mangle]
pub unsafe extern "C" fn tecsSha256(bytes: *const u8, length: usize, output: *mut c_char) -> bool {
    if output.is_null() || (bytes.is_null() && length != 0) {
        return false;
    }

    let input = if bytes.is_null() {
        &[]
    } else {
        // SAFETY: The caller supplies `bytes` under this function's contract.
        unsafe { slice::from_raw_parts(bytes, length) }
    };
    let digest = Sha256::digest(input);

    for (index, byte) in digest.iter().enumerate() {
        // SAFETY: The caller supplies 65 writable bytes. Each digest byte
        // writes two characters within the first 64.
        unsafe {
            *output.add(index * 2) = HEX[(byte >> 4) as usize] as c_char;
            *output.add(index * 2 + 1) = HEX[(byte & 0x0f) as usize] as c_char;
        }
    }
    // SAFETY: The terminator is the final byte in the promised output.
    unsafe {
        *output.add(TEXT_LENGTH) = 0;
    }
    true
}

#[cfg(test)]
mod tests {
    use std::ffi::CStr;
    use std::ptr;

    use super::*;

    fn hash(input: &[u8]) -> String {
        let mut output = [0 as c_char; TEXT_LENGTH + 1];
        // SAFETY: The slice and output array satisfy `tecsSha256`'s contract.
        assert!(unsafe { tecsSha256(input.as_ptr(), input.len(), output.as_mut_ptr()) });
        // SAFETY: A successful hash writes a terminating NUL.
        unsafe { CStr::from_ptr(output.as_ptr()) }
            .to_str()
            .expect("SHA-256 text is ASCII")
            .to_owned()
    }

    #[test]
    fn matches_published_vectors() {
        assert_eq!(
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
            hash(b"")
        );
        assert_eq!(
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
            hash(b"abc")
        );
    }

    #[test]
    fn hashes_binary_input() {
        assert_eq!(
            "a37cc3026aae4d519e0b19c298fa913b4dccfdf0658cbccbb7deaa0226d5acdb",
            hash(&[b'a', 0, b'b', 255])
        );
    }

    #[test]
    fn validates_pointers() {
        let mut output = [0 as c_char; TEXT_LENGTH + 1];
        // SAFETY: Null with zero length represents an empty input.
        assert!(unsafe { tecsSha256(ptr::null(), 0, output.as_mut_ptr()) });
        // SAFETY: Both invalid cases are explicitly accepted and rejected.
        assert!(!unsafe { tecsSha256(ptr::null(), 1, output.as_mut_ptr()) });
        assert!(!unsafe { tecsSha256([0].as_ptr(), 1, ptr::null_mut()) });
    }
}
