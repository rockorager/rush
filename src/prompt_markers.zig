//! Readline-compatible markers around non-printing prompt bytes.

pub const nonprinting_start: u8 = 0x01;
pub const nonprinting_end: u8 = 0x02;

pub fn isMarker(byte: u8) bool {
    return byte == nonprinting_start or byte == nonprinting_end;
}
