// support.rs -- host debug shim for malbr-generated micro ALB
// Replace _alb_putchar with your target UART/write function for embedded builds.

#[cfg(windows)]
#[no_mangle]
pub extern "C" fn _crt_atexit(_f: usize) -> i32 {
    0
}

#[cfg(windows)]
#[allow(static_mut_refs)]
#[no_mangle]
pub extern "C" fn __p___initenv() -> *mut *mut u8 {
    static mut DUMMY: *mut u8 = core::ptr::null_mut();
    unsafe { &mut DUMMY }
}

const STD_OUTPUT_HANDLE: u32 = (-11i32) as u32;

extern "system" {
    fn GetStdHandle(nStdHandle: u32) -> *mut u8;
    fn WriteFile(hFile: *mut u8, lpBuffer: *const u8,
                 nNumberOfBytesToWrite: u32,
                 lpNumberOfBytesWritten: *mut u32,
                 lpOverlapped: *mut u8) -> i32;
}

pub fn _alb_putchar(c: u8) {
    unsafe {
        let h = GetStdHandle(STD_OUTPUT_HANDLE);
        let mut written: u32 = 0;
        let buf = [c; 1];
        WriteFile(h, buf.as_ptr(), 1, &mut written, core::ptr::null_mut());
    }
}

pub fn _alb_print_newline() {
    _alb_putchar(10);
}

pub fn _alb_print_str(s: &str) {
    for b in s.bytes() {
        _alb_putchar(b);
    }
}

#[cfg(windows)]
pub fn _alb_exit(code: u32) {
    extern "system" { fn ExitProcess(uExitCode: u32); }
    unsafe { ExitProcess(code); }
}

#[cfg(not(windows))]
pub fn _alb_exit(_code: u32) -> ! {
    loop {}
}

pub fn _alb_print_i32(v: i32) {
    if v == 0 {
        _alb_putchar(b'0');
        return;
    }
    let mut n: i32 = v;
    let mut buf: [u8; 12] = [0; 12];
    let mut i: usize = 0;
    let neg: bool = n < 0;
    if neg { n = -n; }
    while n != 0 {
        buf[i] = ((n % 10) as u8) + b'0';
        i += 1;
        n /= 10;
    }
    if neg { _alb_putchar(b'-'); }
    while i > 0 {
        i -= 1;
        _alb_putchar(buf[i]);
    }
}
