//! UUID generation across the C ABI.

use std::ffi::c_char;
use std::ptr;

use ::uuid::Uuid;

const UUID_TEXT_LENGTH: usize = 36;

/// Writes a canonical lowercase UUID into a caller-owned C string.
///
/// Returns false without writing when `output` is null.
///
/// # Safety
///
/// `output` must be null or address at least 37 writable bytes.
unsafe fn write(uuid: Uuid, output: *mut c_char) -> bool {
    if output.is_null() {
        return false;
    }

    let mut buffer = Uuid::encode_buffer();
    let text = uuid.hyphenated().encode_lower(&mut buffer);
    // SAFETY: The caller promises space for the 36-byte representation and
    // its terminator. `text` borrows a separate stack buffer.
    unsafe {
        ptr::copy_nonoverlapping(text.as_ptr().cast(), output, UUID_TEXT_LENGTH);
        *output.add(UUID_TEXT_LENGTH) = 0;
    }
    true
}

/// Generates a random RFC 9562 UUID version 4.
///
/// # Safety
///
/// `output` follows `write`'s contract.
#[no_mangle]
pub unsafe extern "C" fn tecsUuid4(output: *mut c_char) -> bool {
    // SAFETY: The caller supplies `output` under this function's contract.
    unsafe { write(Uuid::new_v4(), output) }
}

/// Generates a time-ordered RFC 9562 UUID version 7.
///
/// # Safety
///
/// `output` follows `write`'s contract.
#[no_mangle]
pub unsafe extern "C" fn tecsUuid7(output: *mut c_char) -> bool {
    // SAFETY: The caller supplies `output` under this function's contract.
    unsafe { write(Uuid::now_v7(), output) }
}

#[cfg(test)]
mod tests {
    use std::ffi::CStr;

    use super::*;

    unsafe fn generated(generate: unsafe extern "C" fn(*mut c_char) -> bool) -> Uuid {
        let mut output = [0 as c_char; UUID_TEXT_LENGTH + 1];
        // SAFETY: `output` holds the 37 writable bytes the generator requires.
        assert!(unsafe { generate(output.as_mut_ptr()) });
        // SAFETY: A successful generator writes a terminating NUL.
        let text = unsafe { CStr::from_ptr(output.as_ptr()) }
            .to_str()
            .expect("UUID text is ASCII");
        Uuid::parse_str(text).expect("generated text is a UUID")
    }

    #[test]
    fn uuid4_writes_a_random_uuid() {
        // SAFETY: `generated` supplies the output buffer.
        let first = unsafe { generated(tecsUuid4) };
        // SAFETY: `generated` supplies the output buffer.
        let second = unsafe { generated(tecsUuid4) };

        assert_eq!(Some(::uuid::Version::Random), first.get_version());
        assert_ne!(first, second);
    }

    #[test]
    fn uuid7_writes_ordered_uuids() {
        // SAFETY: `generated` supplies the output buffer.
        let first = unsafe { generated(tecsUuid7) };
        // SAFETY: `generated` supplies the output buffer.
        let second = unsafe { generated(tecsUuid7) };

        assert_eq!(Some(::uuid::Version::SortRand), first.get_version());
        assert!(first < second);
    }

    #[test]
    fn null_output_is_rejected() {
        // SAFETY: Null is an explicitly accepted input.
        assert!(!unsafe { tecsUuid4(ptr::null_mut()) });
        // SAFETY: Null is an explicitly accepted input.
        assert!(!unsafe { tecsUuid7(ptr::null_mut()) });
    }
}
