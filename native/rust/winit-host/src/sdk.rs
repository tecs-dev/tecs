use std::ffi::{c_char, c_int, c_void, CString};
use std::path::Path;
use std::ptr;

use anyhow::{anyhow, bail, Result};

const STATUS_OK: c_int = 0;
const CONFIG_OPEN_LIBRARIES: u32 = 1;
const VALUE_NIL: u32 = 0;
const VALUE_BOOLEAN: u32 = 1;
const VALUE_NUMBER: u32 = 2;
const VALUE_STRING: u32 = 3;
const VALUE_BYTES: u32 = 4;
const VALUE_HANDLE: u32 = 5;
const RESULT_CAPACITY: usize = 16;

#[repr(C)]
struct NuppRuntime {
    _private: [u8; 0],
}

#[repr(C)]
struct NuppComponent {
    _private: [u8; 0],
}

#[repr(C)]
struct NuppHandle {
    _private: [u8; 0],
}

#[repr(C)]
struct NuppError {
    _private: [u8; 0],
}

#[repr(C)]
struct NuppConfig {
    size: u32,
    abi_version: u32,
    flags: u32,
}

#[repr(C)]
struct NuppValue {
    kind: u32,
    boolean: c_int,
    number: f64,
    data: *mut u8,
    length: usize,
    handle: *mut NuppHandle,
}

impl Default for NuppValue {
    fn default() -> Self {
        Self {
            kind: VALUE_NIL,
            boolean: 0,
            number: 0.0,
            data: ptr::null_mut(),
            length: 0,
            handle: ptr::null_mut(),
        }
    }
}

unsafe extern "C" {
    fn nupp_config_init(config: *mut NuppConfig);
    fn nupp_runtime_new(
        config: *const NuppConfig,
        out: *mut *mut NuppRuntime,
        error: *mut *mut NuppError,
    ) -> c_int;
    fn nupp_component_load(
        runtime: *mut NuppRuntime,
        bytes: *const c_void,
        length: usize,
        name: *const c_char,
        out: *mut *mut NuppComponent,
        error: *mut *mut NuppError,
    ) -> c_int;
    fn nupp_component_start(
        runtime: *mut NuppRuntime,
        component: *const NuppComponent,
        argc: c_int,
        argv: *const *const c_char,
        error: *mut *mut NuppError,
    ) -> c_int;
    fn nupp_export_find(
        runtime: *mut NuppRuntime,
        component: *const NuppComponent,
        name: *const c_char,
        out: *mut *mut NuppHandle,
        error: *mut *mut NuppError,
    ) -> c_int;
    fn nupp_call(
        runtime: *mut NuppRuntime,
        callable: *const NuppHandle,
        arguments: *const NuppValue,
        argument_count: usize,
        results: *mut NuppValue,
        result_capacity: usize,
        result_count: *mut usize,
        error: *mut *mut NuppError,
    ) -> c_int;
    fn nupp_handle_release(
        runtime: *mut NuppRuntime,
        handle: *mut NuppHandle,
        error: *mut *mut NuppError,
    ) -> c_int;
    fn nupp_value_release(
        runtime: *mut NuppRuntime,
        value: *mut NuppValue,
        error: *mut *mut NuppError,
    ) -> c_int;
    fn nupp_runtime_shutdown(runtime: *mut NuppRuntime, error: *mut *mut NuppError) -> c_int;
    fn nupp_component_release(component: *mut NuppComponent);
    fn nupp_runtime_free(runtime: *mut NuppRuntime);
    fn nupp_error_message(error: *const NuppError) -> *const c_char;
    fn nupp_error_message_length(error: *const NuppError) -> usize;
    fn nupp_error_free(error: *mut NuppError);
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Component(*mut NuppComponent);

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct ManagedHandle(*mut NuppHandle);

#[derive(Clone, Debug, PartialEq)]
pub enum ManagedValue {
    Nil,
    Boolean(bool),
    Number(f64),
    Bytes(Vec<u8>),
    Handle(ManagedHandle),
}

pub struct HostRuntime {
    raw: *mut NuppRuntime,
    components: Vec<*mut NuppComponent>,
    handles: Vec<*mut NuppHandle>,
    closed: bool,
}

impl HostRuntime {
    pub fn new(_executable: &Path) -> Result<Self> {
        let mut config = NuppConfig {
            size: 0,
            abi_version: 0,
            flags: CONFIG_OPEN_LIBRARIES,
        };
        unsafe { nupp_config_init(&mut config) };
        let mut raw = ptr::null_mut();
        call_status(|error| unsafe { nupp_runtime_new(&config, &mut raw, error) })?;
        if raw.is_null() {
            bail!("nupp_runtime_new returned a null runtime");
        }
        Ok(Self {
            raw,
            components: Vec::new(),
            handles: Vec::new(),
            closed: false,
        })
    }

    pub fn load_component(&mut self, bytes: &[u8], name: &str) -> Result<Component> {
        self.open()?;
        let name = CString::new(name).map_err(|_| anyhow!("component name contains a NUL byte"))?;
        let mut component = ptr::null_mut();
        call_status(|error| unsafe {
            nupp_component_load(
                self.raw,
                bytes.as_ptr().cast(),
                bytes.len(),
                name.as_ptr(),
                &mut component,
                error,
            )
        })?;
        if component.is_null() {
            bail!("nupp_component_load returned a null component");
        }
        self.components.push(component);
        Ok(Component(component))
    }

    pub fn start_component(&mut self, component: Component, arguments: &[Vec<u8>]) -> Result<()> {
        self.open()?;
        let arguments = arguments
            .iter()
            .map(|value| {
                CString::new(value.as_slice())
                    .map_err(|_| anyhow!("component argument contains a NUL byte"))
            })
            .collect::<Result<Vec<_>>>()?;
        let pointers = arguments
            .iter()
            .map(|value| value.as_ptr())
            .collect::<Vec<_>>();
        call_status(|error| unsafe {
            nupp_component_start(
                self.raw,
                component.0,
                pointers.len() as c_int,
                pointers.as_ptr(),
                error,
            )
        })
    }

    pub fn find_export(&mut self, component: Component, name: &str) -> Result<ManagedHandle> {
        self.open()?;
        let name = CString::new(name).map_err(|_| anyhow!("export name contains a NUL byte"))?;
        let mut handle = ptr::null_mut();
        call_status(|error| unsafe {
            nupp_export_find(self.raw, component.0, name.as_ptr(), &mut handle, error)
        })?;
        self.keep_handle(handle)
    }

    pub fn call(
        &mut self,
        callable: ManagedHandle,
        arguments: &[ManagedValue],
    ) -> Result<Vec<ManagedValue>> {
        self.open()?;
        let raw_arguments = arguments.iter().map(raw_argument).collect::<Vec<_>>();
        let mut raw_results = (0..RESULT_CAPACITY)
            .map(|_| NuppValue::default())
            .collect::<Vec<_>>();
        let mut result_count = 0;
        call_status(|error| unsafe {
            nupp_call(
                self.raw,
                callable.0,
                raw_arguments.as_ptr(),
                raw_arguments.len(),
                raw_results.as_mut_ptr(),
                raw_results.len(),
                &mut result_count,
                error,
            )
        })?;
        let mut results = Vec::with_capacity(result_count);
        for raw in raw_results.iter_mut().take(result_count) {
            let value = match raw.kind {
                VALUE_NIL => ManagedValue::Nil,
                VALUE_BOOLEAN => ManagedValue::Boolean(raw.boolean != 0),
                VALUE_NUMBER => ManagedValue::Number(raw.number),
                VALUE_STRING | VALUE_BYTES => {
                    let bytes = if raw.data.is_null() {
                        Vec::new()
                    } else {
                        unsafe { std::slice::from_raw_parts(raw.data, raw.length) }.to_vec()
                    };
                    ManagedValue::Bytes(bytes)
                }
                VALUE_HANDLE => ManagedValue::Handle(self.keep_handle(raw.handle)?),
                kind => bail!("nupp_call returned unknown value kind {kind}"),
            };
            if raw.kind != VALUE_HANDLE {
                call_status(|error| unsafe { nupp_value_release(self.raw, raw, error) })?;
            }
            results.push(value);
        }
        Ok(results)
    }

    pub fn shutdown(&mut self) -> Result<()> {
        if self.closed {
            return Ok(());
        }
        let mut first = None;
        for handle in self.handles.drain(..).rev() {
            if let Err(error) =
                call_status(|detail| unsafe { nupp_handle_release(self.raw, handle, detail) })
            {
                first.get_or_insert(error);
            }
        }
        for component in self.components.drain(..).rev() {
            unsafe { nupp_component_release(component) };
        }
        if let Err(error) = call_status(|detail| unsafe { nupp_runtime_shutdown(self.raw, detail) })
        {
            first.get_or_insert(error);
        }
        unsafe { nupp_runtime_free(self.raw) };
        self.raw = ptr::null_mut();
        self.closed = true;
        match first {
            Some(error) => Err(error),
            None => Ok(()),
        }
    }

    fn keep_handle(&mut self, handle: *mut NuppHandle) -> Result<ManagedHandle> {
        if handle.is_null() {
            bail!("Nupp returned a null managed handle");
        }
        self.handles.push(handle);
        Ok(ManagedHandle(handle))
    }

    fn open(&self) -> Result<()> {
        if self.closed || self.raw.is_null() {
            bail!("the Nupp runtime is closed");
        }
        Ok(())
    }
}

impl Drop for HostRuntime {
    fn drop(&mut self) {
        let _ = self.shutdown();
    }
}

fn raw_argument(value: &ManagedValue) -> NuppValue {
    match value {
        ManagedValue::Nil => NuppValue::default(),
        ManagedValue::Boolean(value) => NuppValue {
            kind: VALUE_BOOLEAN,
            boolean: c_int::from(*value),
            ..NuppValue::default()
        },
        ManagedValue::Number(value) => NuppValue {
            kind: VALUE_NUMBER,
            number: *value,
            ..NuppValue::default()
        },
        ManagedValue::Bytes(value) => NuppValue {
            kind: VALUE_STRING,
            data: value.as_ptr().cast_mut(),
            length: value.len(),
            ..NuppValue::default()
        },
        ManagedValue::Handle(value) => NuppValue {
            kind: VALUE_HANDLE,
            handle: value.0,
            ..NuppValue::default()
        },
    }
}

fn call_status(call: impl FnOnce(*mut *mut NuppError) -> c_int) -> Result<()> {
    let mut error = ptr::null_mut();
    let status = call(&mut error);
    if status == STATUS_OK {
        if !error.is_null() {
            unsafe { nupp_error_free(error) };
        }
        return Ok(());
    }
    if error.is_null() {
        bail!("Nupp embedding call failed with status {status}");
    }
    let message = unsafe {
        let pointer = nupp_error_message(error);
        let length = nupp_error_message_length(error);
        if pointer.is_null() {
            format!("Nupp embedding call failed with status {status}")
        } else {
            String::from_utf8_lossy(std::slice::from_raw_parts(pointer.cast::<u8>(), length))
                .into_owned()
        }
    };
    unsafe { nupp_error_free(error) };
    Err(anyhow!(message))
}
