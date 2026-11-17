//! Desassembleur 8086/8088 (syntaxe NASM) pour le debogueur.

const R8: [&str; 8] = ["al", "cl", "dl", "bl", "ah", "ch", "dh", "bh"];
const R16: [&str; 8] = ["ax", "cx", "dx", "bx", "sp", "bp", "si", "di"];
const SR: [&str; 4] = ["es", "cs", "ss", "ds"];
const ALU: [&str; 8] = ["add", "or", "adc", "sbb", "and", "sub", "xor", "cmp"];
const SHF: [&str; 8] = ["rol", "ror", "rcl", "rcr", "shl", "shr", "shl", "sar"];
const JCC: [&str; 16] = [
    "jo", "jno", "jc", "jnc", "jz", "jnz", "jna", "ja", "js", "jns", "jpe", "jpo", "jl", "jnl", "jng", "jg",
];
const EA: [&str; 8] = ["bx+si", "bx+di", "bp+si", "bp+di", "si", "di", "bp", "bx"];

struct D<'a> {
    f: &'a dyn Fn(u32) -> u8,
    cs: u16,
    ip: u16,
    len: u16,
    seg: Option<&'static str>,
    wide: bool,
}

impl D<'_> {
    fn b(&mut self) -> u8 {
        let a = (((self.cs as u32) << 4) + self.ip.wrapping_add(self.len) as u32) & 0xFFFFF;
        self.len += 1;
        (self.f)(a)
    }
    fn w(&mut self) -> u16 {
        let l = self.b() as u16;
        l | (self.b() as u16) << 8
    }
    fn next_ip(&self) -> u16 {
        self.ip.wrapping_add(self.len)
    }
    /// Operande r/m (taille : 0 = sans prefixe, 1 = byte, 2 = word).
    fn rm(&mut self, m: u8, size: u8) -> String {
        let md = m >> 6;
        let rm = (m & 7) as usize;
        if md == 3 {
            return if size == 1 || (size == 0 && !self.wide) { R8[rm].into() } else { R16[rm].into() };
        }
        let mut s = String::new();
        if size == 1 {
            s.push_str("byte ");
        } else if size == 2 {
            s.push_str("word ");
        }
        s.push('[');
        if let Some(sg) = self.seg {
            s.push_str(sg);
            s.push(':');
        }
        match md {
            0 if rm == 6 => {
                let d = self.w();
                s.push_str(&format!("0x{:x}", d));
            }
            0 => s.push_str(EA[rm]),
            1 => {
                let d = self.b() as i8;
                s.push_str(EA[rm]);
                if d < 0 {
                    s.push_str(&format!("-0x{:x}", -(d as i16)));
                } else {
                    s.push_str(&format!("+0x{:x}", d));
                }
            }
            _ => {
                let d = self.w();
                s.push_str(&format!("{}+0x{:x}", EA[rm], d));
            }
        }
        s.push(']');
        s
    }
}

/// Desassemble l'instruction en CS:IP. Rend (texte, longueur).
pub fn disasm(f: &dyn Fn(u32) -> u8, cs: u16, ip: u16) -> (String, u16) {
    let mut d = D { f, cs, ip, len: 0, seg: None, wide: true };
    let mut prefix = String::new();
    let mut op;
    loop {
        op = d.b();
        match op {
            0x26 => d.seg = Some("es"),
            0x2E => d.seg = Some("cs"),
            0x36 => d.seg = Some("ss"),
            0x3E => d.seg = Some("ds"),
            0xF0 => prefix.push_str("lock "),
            0xF2 => prefix.push_str("repne "),
            0xF3 => prefix.push_str("rep "),
            _ => break,
        }
        if d.len > 6 {
            break;
        }
    }
    d.wide = op & 1 != 0 || matches!(op, 0x8C..=0x8E | 0xC4 | 0xC5 | 0xD8..=0xDF);
    let t: String = match op {
        0x00..=0x3F if op & 7 < 6 => {
            let name = ALU[(op >> 3) as usize];
            match op & 7 {
                0 => {
                    let m = d.b();
                    format!("{} {}, {}", name, d.rm(m, 0), R8[(m >> 3 & 7) as usize])
                }
                1 => {
                    let m = d.b();
                    format!("{} {}, {}", name, d.rm(m, 0), R16[(m >> 3 & 7) as usize])
                }
                2 => {
                    let m = d.b();
                    let r = d.rm(m, 0);
                    format!("{} {}, {}", name, R8[(m >> 3 & 7) as usize], r)
                }
                3 => {
                    let m = d.b();
                    let r = d.rm(m, 0);
                    format!("{} {}, {}", name, R16[(m >> 3 & 7) as usize], r)
                }
                4 => format!("{} al, 0x{:x}", name, d.b()),
                _ => format!("{} ax, 0x{:x}", name, d.w()),
            }
        }
        0x06 | 0x0E | 0x16 | 0x1E => format!("push {}", SR[(op >> 3 & 3) as usize]),
        0x07 | 0x0F | 0x17 | 0x1F => format!("pop {}", SR[(op >> 3 & 3) as usize]),
        0x27 => "daa".into(),
        0x2F => "das".into(),
        0x37 => "aaa".into(),
        0x3F => "aas".into(),
        0x40..=0x47 => format!("inc {}", R16[(op & 7) as usize]),
        0x48..=0x4F => format!("dec {}", R16[(op & 7) as usize]),
        0x50..=0x57 => format!("push {}", R16[(op & 7) as usize]),
        0x58..=0x5F => format!("pop {}", R16[(op & 7) as usize]),
        0x60..=0x7F => {
            let r = d.b() as i8 as i16 as u16;
            format!("{} 0x{:04x}", JCC[(op & 15) as usize], d.next_ip().wrapping_add(r))
        }
        0x80..=0x83 => {
            let m = d.b();
            let sz = if op & 1 != 0 { 2 } else { 1 };
            let r = d.rm(m, sz);
            let v = match op {
                0x81 => format!("0x{:x}", d.w()),
                0x83 => {
                    let x = d.b() as i8;
                    if x < 0 {
                        format!("-0x{:x}", -(x as i16))
                    } else {
                        format!("0x{:x}", x)
                    }
                }
                _ => format!("0x{:x}", d.b()),
            };
            format!("{} {}, {}", ALU[(m >> 3 & 7) as usize], r, v)
        }
        0x84..=0x8B => {
            let m = d.b();
            let w = op & 1 != 0;
            let reg = if w { R16[(m >> 3 & 7) as usize] } else { R8[(m >> 3 & 7) as usize] };
            let r = d.rm(m, 0);
            let name = match op {
                0x84 | 0x85 => "test",
                0x86 | 0x87 => "xchg",
                _ => "mov",
            };
            if op == 0x8A || op == 0x8B {
                format!("{} {}, {}", name, reg, r)
            } else {
                format!("{} {}, {}", name, r, reg)
            }
        }
        0x8C => {
            let m = d.b();
            format!("mov {}, {}", d.rm(m, 0), SR[(m >> 3 & 3) as usize])
        }
        0x8D => {
            let m = d.b();
            let r = d.rm(m, 0);
            format!("lea {}, {}", R16[(m >> 3 & 7) as usize], r)
        }
        0x8E => {
            let m = d.b();
            let r = d.rm(m, 0);
            format!("mov {}, {}", SR[(m >> 3 & 3) as usize], r)
        }
        0x8F => {
            let m = d.b();
            format!("pop {}", d.rm(m, 2))
        }
        0x90 => "nop".into(),
        0x91..=0x97 => format!("xchg ax, {}", R16[(op & 7) as usize]),
        0x98 => "cbw".into(),
        0x99 => "cwd".into(),
        0x9A => {
            let o = d.w();
            let s = d.w();
            format!("call 0x{:04x}:0x{:04x}", s, o)
        }
        0x9B => "wait".into(),
        0x9C => "pushf".into(),
        0x9D => "popf".into(),
        0x9E => "sahf".into(),
        0x9F => "lahf".into(),
        0xA0..=0xA3 => {
            let a = d.w();
            let sg = d.seg.map(|s| format!("{}:", s)).unwrap_or_default();
            match op {
                0xA0 => format!("mov al, [{}0x{:x}]", sg, a),
                0xA1 => format!("mov ax, [{}0x{:x}]", sg, a),
                0xA2 => format!("mov [{}0x{:x}], al", sg, a),
                _ => format!("mov [{}0x{:x}], ax", sg, a),
            }
        }
        0xA4 => "movsb".into(),
        0xA5 => "movsw".into(),
        0xA6 => "cmpsb".into(),
        0xA7 => "cmpsw".into(),
        0xA8 => format!("test al, 0x{:x}", d.b()),
        0xA9 => format!("test ax, 0x{:x}", d.w()),
        0xAA => "stosb".into(),
        0xAB => "stosw".into(),
        0xAC => "lodsb".into(),
        0xAD => "lodsw".into(),
        0xAE => "scasb".into(),
        0xAF => "scasw".into(),
        0xB0..=0xB7 => format!("mov {}, 0x{:x}", R8[(op & 7) as usize], d.b()),
        0xB8..=0xBF => format!("mov {}, 0x{:x}", R16[(op & 7) as usize], d.w()),
        0xC0 | 0xC2 => format!("ret 0x{:x}", d.w()),
        0xC1 | 0xC3 => "ret".into(),
        0xC4 | 0xC5 => {
            let m = d.b();
            let r = d.rm(m, 0);
            format!("{} {}, {}", if op == 0xC4 { "les" } else { "lds" }, R16[(m >> 3 & 7) as usize], r)
        }
        0xC6 => {
            let m = d.b();
            let r = d.rm(m, 1);
            format!("mov {}, 0x{:x}", r, d.b())
        }
        0xC7 => {
            let m = d.b();
            let r = d.rm(m, 2);
            format!("mov {}, 0x{:x}", r, d.w())
        }
        0xC8 | 0xCA => format!("retf 0x{:x}", d.w()),
        0xC9 | 0xCB => "retf".into(),
        0xCC => "int3".into(),
        0xCD => format!("int 0x{:02x}", d.b()),
        0xCE => "into".into(),
        0xCF => "iret".into(),
        0xD0..=0xD3 => {
            let m = d.b();
            let sz = if op & 1 != 0 { 2 } else { 1 };
            let r = d.rm(m, sz);
            format!("{} {}, {}", SHF[(m >> 3 & 7) as usize], r, if op >= 0xD2 { "cl" } else { "1" })
        }
        0xD4 => format!("aam 0x{:x}", d.b()),
        0xD5 => format!("aad 0x{:x}", d.b()),
        0xD6 => "salc".into(),
        0xD7 => "xlatb".into(),
        0xD8..=0xDF => {
            let m = d.b();
            format!("esc 0x{:x}, {}", ((op & 7) << 3) | (m >> 3 & 7), d.rm(m, 0))
        }
        0xE0..=0xE3 => {
            let r = d.b() as i8 as i16 as u16;
            let n = ["loopne", "loope", "loop", "jcxz"][(op & 3) as usize];
            format!("{} 0x{:04x}", n, d.next_ip().wrapping_add(r))
        }
        0xE4 => format!("in al, 0x{:x}", d.b()),
        0xE5 => format!("in ax, 0x{:x}", d.b()),
        0xE6 => format!("out 0x{:x}, al", d.b()),
        0xE7 => format!("out 0x{:x}, ax", d.b()),
        0xE8 => {
            let r = d.w();
            format!("call 0x{:04x}", d.next_ip().wrapping_add(r))
        }
        0xE9 => {
            let r = d.w();
            format!("jmp 0x{:04x}", d.next_ip().wrapping_add(r))
        }
        0xEA => {
            let o = d.w();
            let s = d.w();
            format!("jmp 0x{:04x}:0x{:04x}", s, o)
        }
        0xEB => {
            let r = d.b() as i8 as i16 as u16;
            format!("jmp short 0x{:04x}", d.next_ip().wrapping_add(r))
        }
        0xEC => "in al, dx".into(),
        0xED => "in ax, dx".into(),
        0xEE => "out dx, al".into(),
        0xEF => "out dx, ax".into(),
        0xF1 => "db 0xf1".into(),
        0xF4 => "hlt".into(),
        0xF5 => "cmc".into(),
        0xF6 | 0xF7 => {
            let m = d.b();
            let sz = if op & 1 != 0 { 2 } else { 1 };
            let r = d.rm(m, sz);
            let sub = (m >> 3 & 7) as usize;
            if sub < 2 {
                let v = if sz == 2 { d.w() } else { d.b() as u16 };
                format!("test {}, 0x{:x}", r, v)
            } else {
                format!("{} {}", ["", "", "not", "neg", "mul", "imul", "div", "idiv"][sub], r)
            }
        }
        0xF8 => "clc".into(),
        0xF9 => "stc".into(),
        0xFA => "cli".into(),
        0xFB => "sti".into(),
        0xFC => "cld".into(),
        0xFD => "std".into(),
        0xFE => {
            let m = d.b();
            let r = d.rm(m, 1);
            match m >> 3 & 7 {
                0 => format!("inc {}", r),
                1 => format!("dec {}", r),
                _ => format!("db 0xfe ; {}", r),
            }
        }
        0xFF => {
            let m = d.b();
            let sub = m >> 3 & 7;
            let r = d.rm(m, if sub == 3 || sub == 5 { 0 } else { 2 });
            match sub {
                0 => format!("inc {}", r),
                1 => format!("dec {}", r),
                2 => format!("call {}", r),
                3 => format!("call far {}", r),
                4 => format!("jmp {}", r),
                5 => format!("jmp far {}", r),
                _ => format!("push {}", r),
            }
        }
        _ => format!("db 0x{:02x}", op),
    };
    (format!("{}{}", prefix, t), d.len)
}
