/**
 * Interface du simulateur (exportee vers JavaScript).
 */
export class Sim {
    __destroy_into_raw() {
        const ptr = this.__wbg_ptr;
        this.__wbg_ptr = 0;
        SimFinalization.unregister(this);
        return ptr;
    }
    free() {
        const ptr = this.__destroy_into_raw();
        wasm.__wbg_sim_free(ptr, 0);
    }
    /**
     * @param {number} rate
     * @returns {Float32Array}
     */
    audio(rate) {
        const ret = wasm.sim_audio(this.__wbg_ptr, rate);
        var v1 = getArrayF32FromWasm0(ret[0], ret[1]).slice();
        wasm.__wbindgen_free(ret[0], ret[1] * 4, 4);
        return v1;
    }
    /**
     * @param {boolean} on
     */
    audio_enable(on) {
        wasm.sim_audio_enable(this.__wbg_ptr, on);
    }
    /**
     * Etat interne d'une puce pour l'inspecteur (texte multiligne).
     * @param {string} r
     * @returns {string}
     */
    chip_info(r) {
        let deferred2_0;
        let deferred2_1;
        try {
            const ptr0 = passStringToWasm0(r, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
            const len0 = WASM_VECTOR_LEN;
            const ret = wasm.sim_chip_info(this.__wbg_ptr, ptr0, len0);
            deferred2_0 = ret[0];
            deferred2_1 = ret[1];
            return getStringFromWasm0(ret[0], ret[1]);
        } finally {
            wasm.__wbindgen_free(deferred2_0, deferred2_1, 1);
        }
    }
    /**
     * @returns {number}
     */
    static clk_hz() {
        const ret = wasm.sim_clk_hz();
        return ret;
    }
    /**
     * @returns {number}
     */
    cycles() {
        const ret = wasm.sim_cycles(this.__wbg_ptr);
        return ret;
    }
    /**
     * Lignes "adresse lineaire|CS:IP|octets|texte".
     * @param {number} cs
     * @param {number} ip
     * @param {number} count
     * @returns {string}
     */
    disasm(cs, ip, count) {
        let deferred1_0;
        let deferred1_1;
        try {
            const ret = wasm.sim_disasm(this.__wbg_ptr, cs, ip, count);
            deferred1_0 = ret[0];
            deferred1_1 = ret[1];
            return getStringFromWasm0(ret[0], ret[1]);
        } finally {
            wasm.__wbindgen_free(deferred1_0, deferred1_1, 1);
        }
    }
    /**
     * @returns {boolean}
     */
    has_snapshot() {
        const ret = wasm.sim_has_snapshot(this.__wbg_ptr);
        return ret !== 0;
    }
    /**
     * @returns {boolean}
     */
    in_reset() {
        const ret = wasm.sim_in_reset(this.__wbg_ptr);
        return ret !== 0;
    }
    /**
     * Longueur de l'instruction en CS:IP (pour le pas a pas "par-dessus").
     * @param {number} cs
     * @param {number} ip
     * @returns {number}
     */
    insn_len(cs, ip) {
        const ret = wasm.sim_insn_len(this.__wbg_ptr, cs, ip);
        return ret >>> 0;
    }
    /**
     * @returns {number}
     */
    instructions() {
        const ret = wasm.sim_instructions(this.__wbg_ptr);
        return ret;
    }
    /**
     * @returns {string}
     */
    io_history() {
        let deferred1_0;
        let deferred1_1;
        try {
            const ret = wasm.sim_io_history(this.__wbg_ptr);
            deferred1_0 = ret[0];
            deferred1_1 = ret[1];
            return getStringFromWasm0(ret[0], ret[1]);
        } finally {
            wasm.__wbindgen_free(deferred1_0, deferred1_1, 1);
        }
    }
    /**
     * Demasque de force IRn (2, 3, 5, 6, 7) : comme un programme qui ecrirait l'IMR.
     * @param {number} n
     * @param {boolean} on
     */
    irq_enable(n, on) {
        wasm.sim_irq_enable(this.__wbg_ptr, n, on);
    }
    /**
     * Fin d'interruption simulee pour les entrees libres (le BIOS les pointe sur un IRET seul).
     * @param {boolean} on
     */
    irq_sim_eoi(on) {
        wasm.sim_irq_sim_eoi(this.__wbg_ptr, on);
    }
    /**
     * Etat du 8259 : [IMR, forcage, ISR, IRR, niveaux IR, demandes J12, initialise].
     * @returns {Uint8Array}
     */
    irq_state() {
        const ret = wasm.sim_irq_state(this.__wbg_ptr);
        var v1 = getArrayU8FromWasm0(ret[0], ret[1]).slice();
        wasm.__wbindgen_free(ret[0], ret[1] * 1, 1);
        return v1;
    }
    /**
     * Front montant sur IRn (J12), tenu jusqu'a INTA ou `ms` millisecondes.
     * @param {number} n
     * @param {number} ms
     * @returns {boolean}
     */
    irq_trigger(n, ms) {
        const ret = wasm.sim_irq_trigger(this.__wbg_ptr, n, ms);
        return ret !== 0;
    }
    /**
     * @param {Uint8Array | number[]} bytes
     */
    kbd(bytes) {
        const ptr0 = passArray8ToWasm0(bytes, wasm.__wbindgen_malloc);
        const len0 = WASM_VECTOR_LEN;
        wasm.sim_kbd(this.__wbg_ptr, ptr0, len0);
    }
    /**
     * @returns {number}
     */
    kbd_pending() {
        const ret = wasm.sim_kbd_pending(this.__wbg_ptr);
        return ret >>> 0;
    }
    /**
     * 80 codes visibles, 64 octets de CGRAM, puis : allume, curseur, clignotement,
     * initialise, 2 lignes, ligne du curseur (255 = aucun), colonne, version (4 octets).
     * @returns {Uint8Array}
     */
    lcd() {
        const ret = wasm.sim_lcd(this.__wbg_ptr);
        var v1 = getArrayU8FromWasm0(ret[0], ret[1]).slice();
        wasm.__wbindgen_free(ret[0], ret[1] * 1, 1);
        return v1;
    }
    /**
     * @param {Uint8Array | number[]} rom
     */
    constructor(rom) {
        const ptr0 = passArray8ToWasm0(rom, wasm.__wbindgen_malloc);
        const len0 = WASM_VECTOR_LEN;
        const ret = wasm.sim_new(ptr0, len0);
        this.__wbg_ptr = ret;
        SimFinalization.register(this, this.__wbg_ptr, this);
        return this;
    }
    /**
     * @param {number} addr
     * @param {number} len
     * @returns {Uint8Array}
     */
    peek(addr, len) {
        const ret = wasm.sim_peek(this.__wbg_ptr, addr, len);
        var v1 = getArrayU8FromWasm0(ret[0], ret[1]).slice();
        wasm.__wbindgen_free(ret[0], ret[1] * 1, 1);
        return v1;
    }
    /**
     * @param {number} addr
     * @param {number} v
     */
    poke(addr, v) {
        wasm.sim_poke(this.__wbg_ptr, addr, v);
    }
    /**
     * @param {boolean} on
     */
    power(on) {
        wasm.sim_power(this.__wbg_ptr, on);
    }
    /**
     * @returns {boolean}
     */
    powered() {
        const ret = wasm.sim_powered(this.__wbg_ptr);
        return ret !== 0;
    }
    /**
     * AX CX DX BX SP BP SI DI ES CS SS DS IP FLAGS HALT
     * @returns {Uint16Array}
     */
    regs() {
        const ret = wasm.sim_regs(this.__wbg_ptr);
        var v1 = getArrayU16FromWasm0(ret[0], ret[1]).slice();
        wasm.__wbindgen_free(ret[0], ret[1] * 2, 2);
        return v1;
    }
    /**
     * @param {boolean} down
     */
    reset_button(down) {
        wasm.sim_reset_button(this.__wbg_ptr, down);
    }
    /**
     * @returns {boolean}
     */
    restore() {
        const ret = wasm.sim_restore(this.__wbg_ptr);
        return ret !== 0;
    }
    /**
     * Execute `cycles` cycles. Rend 0 (fini), 1 (point d'arret), 3 (hors tension).
     * @param {number} cycles
     * @returns {number}
     */
    run(cycles) {
        const ret = wasm.sim_run(this.__wbg_ptr, cycles);
        return ret >>> 0;
    }
    /**
     * @param {string} name
     * @param {Uint8Array | number[]} data
     */
    sd_add_file(name, data) {
        let ptr0, len0, ptr1, len1;
        try {
            ptr0 = passStringToWasm0(name, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
            len0 = WASM_VECTOR_LEN;
            ptr1 = passArray8ToWasm0(data, wasm.__wbindgen_malloc);
            len1 = WASM_VECTOR_LEN;
        } catch (e) {
            if (ptr1) { wasm.__wbindgen_free(ptr1, len1 * 1, 1); }
            if (ptr0) { wasm.__wbindgen_free(ptr0, len0 * 1, 1); }
            throw e;
        }
        wasm.sim_sd_add_file(this.__wbg_ptr, ptr0, len0, ptr1, len1);
    }
    sd_clear_files() {
        wasm.sim_sd_clear_files(this.__wbg_ptr);
    }
    sd_eject() {
        wasm.sim_sd_eject(this.__wbg_ptr);
    }
    /**
     * @param {number} i
     * @returns {Uint8Array}
     */
    sd_file(i) {
        const ret = wasm.sim_sd_file(this.__wbg_ptr, i);
        var v1 = getArrayU8FromWasm0(ret[0], ret[1]).slice();
        wasm.__wbindgen_free(ret[0], ret[1] * 1, 1);
        return v1;
    }
    /**
     * JSON : [{"name":..,"size":..,"lba":..,"dirty":..}, ...]
     * @returns {string}
     */
    sd_files() {
        let deferred1_0;
        let deferred1_1;
        try {
            const ret = wasm.sim_sd_files(this.__wbg_ptr);
            deferred1_0 = ret[0];
            deferred1_1 = ret[1];
            return getStringFromWasm0(ret[0], ret[1]);
        } finally {
            wasm.__wbindgen_free(deferred1_0, deferred1_1, 1);
        }
    }
    /**
     * Formate une carte FAT32 avec les fichiers ajoutes et l'insere.
     */
    sd_insert_built() {
        wasm.sim_sd_insert_built(this.__wbg_ptr);
    }
    /**
     * Insere une image brute de carte entiere.
     * @param {Uint8Array | number[]} data
     */
    sd_insert_raw(data) {
        const ptr0 = passArray8ToWasm0(data, wasm.__wbindgen_malloc);
        const len0 = WASM_VECTOR_LEN;
        wasm.sim_sd_insert_raw(this.__wbg_ptr, ptr0, len0);
    }
    /**
     * @returns {boolean}
     */
    sd_present() {
        const ret = wasm.sim_sd_present(this.__wbg_ptr);
        return ret !== 0;
    }
    /**
     * lectures, ecritures, dernier LBA, derniere commande
     * @returns {Float64Array}
     */
    sd_stats() {
        const ret = wasm.sim_sd_stats(this.__wbg_ptr);
        var v1 = getArrayF64FromWasm0(ret[0], ret[1]).slice();
        wasm.__wbindgen_free(ret[0], ret[1] * 8, 8);
        return v1;
    }
    /**
     * @param {Uint32Array | number[]} bps
     */
    set_breakpoints(bps) {
        const ptr0 = passArray32ToWasm0(bps, wasm.__wbindgen_malloc);
        const len0 = WASM_VECTOR_LEN;
        wasm.sim_set_breakpoints(this.__wbg_ptr, ptr0, len0);
    }
    /**
     * @param {string} name
     * @param {number} v
     */
    set_fault(name, v) {
        const val2 = +v;
        const ptr0 = passStringToWasm0(name, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
        const len0 = WASM_VECTOR_LEN;
        wasm.sim_set_fault(this.__wbg_ptr, ptr0, len0, val2);
    }
    /**
     * @param {Uint8Array | number[]} ids
     */
    set_probes(ids) {
        const ptr0 = passArray8ToWasm0(ids, wasm.__wbindgen_malloc);
        const len0 = WASM_VECTOR_LEN;
        wasm.sim_set_probes(this.__wbg_ptr, ptr0, len0);
    }
    /**
     * @param {number} i
     * @param {number} v
     */
    set_reg(i, v) {
        wasm.sim_set_reg(this.__wbg_ptr, i, v);
    }
    /**
     * @param {Uint8Array | number[]} rom
     */
    set_rom(rom) {
        const ptr0 = passArray8ToWasm0(rom, wasm.__wbindgen_malloc);
        const len0 = WASM_VECTOR_LEN;
        wasm.sim_set_rom(this.__wbg_ptr, ptr0, len0);
    }
    /**
     * @returns {string}
     */
    static signal_names() {
        let deferred1_0;
        let deferred1_1;
        try {
            const ret = wasm.sim_signal_names();
            deferred1_0 = ret[0];
            deferred1_1 = ret[1];
            return getStringFromWasm0(ret[0], ret[1]);
        } finally {
            wasm.__wbindgen_free(deferred1_0, deferred1_1, 1);
        }
    }
    /**
     * @returns {Uint8Array}
     */
    signals() {
        const ret = wasm.sim_signals(this.__wbg_ptr);
        var v1 = getArrayU8FromWasm0(ret[0], ret[1]).slice();
        wasm.__wbindgen_free(ret[0], ret[1] * 1, 1);
        return v1;
    }
    snapshot() {
        wasm.sim_snapshot(this.__wbg_ptr);
    }
    /**
     * Statistiques (JSON).
     * @returns {string}
     */
    stats() {
        let deferred1_0;
        let deferred1_1;
        try {
            const ret = wasm.sim_stats(this.__wbg_ptr);
            deferred1_0 = ret[0];
            deferred1_1 = ret[1];
            return getStringFromWasm0(ret[0], ret[1]);
        } finally {
            wasm.__wbindgen_free(deferred1_0, deferred1_1, 1);
        }
    }
    step() {
        wasm.sim_step(this.__wbg_ptr);
    }
    /**
     * Changements sondes : triplets (instant bas, instant haut, signal << 8 | niveau),
     * instant en quarts de cycle d'horloge.
     * @returns {Uint32Array}
     */
    take_events() {
        const ret = wasm.sim_take_events(this.__wbg_ptr);
        var v1 = getArrayU32FromWasm0(ret[0], ret[1]).slice();
        wasm.__wbindgen_free(ret[0], ret[1] * 4, 4);
        return v1;
    }
    /**
     * Interruptions libres servies depuis la derniere lecture : triplets (cycle, IRn, vecteur).
     * @returns {Float64Array}
     */
    take_irq_events() {
        const ret = wasm.sim_take_irq_events(this.__wbg_ptr);
        var v1 = getArrayF64FromWasm0(ret[0], ret[1]).slice();
        wasm.__wbindgen_free(ret[0], ret[1] * 8, 8);
        return v1;
    }
    /**
     * Messages des modeles (delais du LCD, modes inattendus...), vides apres lecture.
     * @returns {string}
     */
    take_log() {
        let deferred1_0;
        let deferred1_1;
        try {
            const ret = wasm.sim_take_log(this.__wbg_ptr);
            deferred1_0 = ret[0];
            deferred1_1 = ret[1];
            return getStringFromWasm0(ret[0], ret[1]);
        } finally {
            wasm.__wbindgen_free(deferred1_0, deferred1_1, 1);
        }
    }
    /**
     * @param {boolean} on
     */
    term_connected(on) {
        wasm.sim_term_connected(this.__wbg_ptr, on);
    }
    /**
     * @returns {Uint32Array}
     */
    trace() {
        const ret = wasm.sim_trace(this.__wbg_ptr);
        var v1 = getArrayU32FromWasm0(ret[0], ret[1]).slice();
        wasm.__wbindgen_free(ret[0], ret[1] * 4, 4);
        return v1;
    }
    /**
     * Ecart supplementaire entre deux octets envoyes au 8088 (microsecondes).
     * @param {number} us
     */
    uart_gap_us(us) {
        wasm.sim_uart_gap_us(this.__wbg_ptr, us);
    }
    /**
     * @returns {number}
     */
    uart_pending() {
        const ret = wasm.sim_uart_pending(this.__wbg_ptr);
        return ret >>> 0;
    }
    /**
     * @param {Uint8Array | number[]} bytes
     */
    uart_send(bytes) {
        const ptr0 = passArray8ToWasm0(bytes, wasm.__wbindgen_malloc);
        const len0 = WASM_VECTOR_LEN;
        wasm.sim_uart_send(this.__wbg_ptr, ptr0, len0);
    }
    /**
     * @returns {Uint8Array}
     */
    uart_take() {
        const ret = wasm.sim_uart_take(this.__wbg_ptr);
        var v1 = getArrayU8FromWasm0(ret[0], ret[1]).slice();
        wasm.__wbindgen_free(ret[0], ret[1] * 1, 1);
        return v1;
    }
}
if (Symbol.dispose) Sim.prototype[Symbol.dispose] = Sim.prototype.free;
function __wbg_get_imports() {
    const import0 = {
        __proto__: null,
        __wbg___wbindgen_throw_4c88d8bf264fd984: function(arg0, arg1) {
            throw new Error(getStringFromWasm0(arg0, arg1));
        },
        __wbindgen_init_externref_table: function() {
            const table = wasm.__wbindgen_externrefs;
            table.set(0, undefined);
            table.set(1024, undefined);
            table.set(1025, null);
            table.set(1026, true);
            table.set(1027, false);
        },
    };
    return {
        __proto__: null,
        "./s02sim_bg.js": import0,
    };
}

const SimFinalization = (typeof FinalizationRegistry === 'undefined')
    ? { register: () => {}, unregister: () => {} }
    : new FinalizationRegistry(ptr => wasm.__wbg_sim_free(ptr, 1));

function getArrayF32FromWasm0(ptr, len) {
    ptr = ptr >>> 0;
    return getFloat32ArrayMemory0().subarray(ptr / 4, ptr / 4 + len);
}

function getArrayF64FromWasm0(ptr, len) {
    ptr = ptr >>> 0;
    return getFloat64ArrayMemory0().subarray(ptr / 8, ptr / 8 + len);
}

function getArrayU16FromWasm0(ptr, len) {
    ptr = ptr >>> 0;
    return getUint16ArrayMemory0().subarray(ptr / 2, ptr / 2 + len);
}

function getArrayU32FromWasm0(ptr, len) {
    ptr = ptr >>> 0;
    return getUint32ArrayMemory0().subarray(ptr / 4, ptr / 4 + len);
}

function getArrayU8FromWasm0(ptr, len) {
    ptr = ptr >>> 0;
    return getUint8ArrayMemory0().subarray(ptr / 1, ptr / 1 + len);
}

let cachedFloat32ArrayMemory0 = null;
function getFloat32ArrayMemory0() {
    if (cachedFloat32ArrayMemory0 === null || cachedFloat32ArrayMemory0.byteLength === 0) {
        cachedFloat32ArrayMemory0 = new Float32Array(wasm.memory.buffer);
    }
    return cachedFloat32ArrayMemory0;
}

let cachedFloat64ArrayMemory0 = null;
function getFloat64ArrayMemory0() {
    if (cachedFloat64ArrayMemory0 === null || cachedFloat64ArrayMemory0.byteLength === 0) {
        cachedFloat64ArrayMemory0 = new Float64Array(wasm.memory.buffer);
    }
    return cachedFloat64ArrayMemory0;
}

function getStringFromWasm0(ptr, len) {
    ptr = ptr >>> 0;
    return decodeText(getUint8ArrayMemory0().subarray(ptr, ptr + len));
}

let cachedUint16ArrayMemory0 = null;
function getUint16ArrayMemory0() {
    if (cachedUint16ArrayMemory0 === null || cachedUint16ArrayMemory0.byteLength === 0) {
        cachedUint16ArrayMemory0 = new Uint16Array(wasm.memory.buffer);
    }
    return cachedUint16ArrayMemory0;
}

let cachedUint32ArrayMemory0 = null;
function getUint32ArrayMemory0() {
    if (cachedUint32ArrayMemory0 === null || cachedUint32ArrayMemory0.byteLength === 0) {
        cachedUint32ArrayMemory0 = new Uint32Array(wasm.memory.buffer);
    }
    return cachedUint32ArrayMemory0;
}

let cachedUint8ArrayMemory0 = null;
function getUint8ArrayMemory0() {
    if (cachedUint8ArrayMemory0 === null || cachedUint8ArrayMemory0.byteLength === 0) {
        cachedUint8ArrayMemory0 = new Uint8Array(wasm.memory.buffer);
    }
    return cachedUint8ArrayMemory0;
}

function passArray32ToWasm0(arg, malloc) {
    const ptr = malloc(arg.length * 4, 4) >>> 0;
    getUint32ArrayMemory0().set(arg, ptr / 4);
    WASM_VECTOR_LEN = arg.length;
    return ptr;
}

function passArray8ToWasm0(arg, malloc) {
    const ptr = malloc(arg.length * 1, 1) >>> 0;
    getUint8ArrayMemory0().set(arg, ptr / 1);
    WASM_VECTOR_LEN = arg.length;
    return ptr;
}

function passStringToWasm0(arg, malloc, realloc) {
    if (realloc === undefined) {
        const buf = cachedTextEncoder.encode(arg);
        const ptr = malloc(buf.length, 1) >>> 0;
        getUint8ArrayMemory0().subarray(ptr, ptr + buf.length).set(buf);
        WASM_VECTOR_LEN = buf.length;
        return ptr;
    }

    let len = arg.length;
    let ptr = malloc(len, 1) >>> 0;

    const mem = getUint8ArrayMemory0();

    let offset = 0;

    for (; offset < len; offset++) {
        const code = arg.charCodeAt(offset);
        if (code > 0x7F) break;
        mem[ptr + offset] = code;
    }
    if (offset !== len) {
        if (offset !== 0) {
            arg = arg.slice(offset);
        }
        ptr = realloc(ptr, len, len = offset + arg.length * 3, 1) >>> 0;
        const view = getUint8ArrayMemory0().subarray(ptr + offset, ptr + len);
        const ret = cachedTextEncoder.encodeInto(arg, view);

        offset += ret.written;
        ptr = realloc(ptr, len, offset, 1) >>> 0;
    }

    WASM_VECTOR_LEN = offset;
    return ptr;
}

let cachedTextDecoder = new TextDecoder('utf-8', { ignoreBOM: true });
cachedTextDecoder.decode();
const MAX_SAFARI_DECODE_BYTES = 2146435072;
let numBytesDecoded = 0;
function decodeText(bytes) {
    numBytesDecoded += bytes.length;
    if (numBytesDecoded >= MAX_SAFARI_DECODE_BYTES) {
        cachedTextDecoder = new TextDecoder('utf-8', { ignoreBOM: true });
        cachedTextDecoder.decode();
        numBytesDecoded = bytes.length;
    }
    return cachedTextDecoder.decode(bytes);
}

const cachedTextEncoder = new TextEncoder();

if (!('encodeInto' in cachedTextEncoder)) {
    cachedTextEncoder.encodeInto = function (arg, view) {
        const buf = cachedTextEncoder.encode(arg);
        view.set(buf);
        return {
            read: arg.length,
            written: buf.length
        };
    };
}

let WASM_VECTOR_LEN = 0;

let wasmModule, wasmInstance, wasm;
function __wbg_finalize_init(instance, module) {
    wasmInstance = instance;
    wasm = instance.exports;
    wasmModule = module;
    cachedFloat32ArrayMemory0 = null;
    cachedFloat64ArrayMemory0 = null;
    cachedUint16ArrayMemory0 = null;
    cachedUint32ArrayMemory0 = null;
    cachedUint8ArrayMemory0 = null;
    wasm.__wbindgen_start();
    return wasm;
}

async function __wbg_load(module, imports) {
    if (typeof Response === 'function' && module instanceof Response) {
        if (!module.ok) {
            throw new Error(`failed to fetch Wasm: ${module.status} ${module.statusText} fetching '${module.url}'`);
        }

        if (typeof WebAssembly.instantiateStreaming === 'function') {
            try {
                return await WebAssembly.instantiateStreaming(module, imports);
            } catch (e) {
                const validResponse = expectedResponseType(module.type);

                if (validResponse && module.headers.get('Content-Type') !== 'application/wasm') {
                    console.warn("`WebAssembly.instantiateStreaming` failed because your server does not serve Wasm with `application/wasm` MIME type. Falling back to `WebAssembly.instantiate` which is slower. Original error:\n", e);

                } else { throw e; }
            }
        }

        const bytes = await module.arrayBuffer();
        return await WebAssembly.instantiate(bytes, imports);
    } else {
        const instance = await WebAssembly.instantiate(module, imports);

        if (instance instanceof WebAssembly.Instance) {
            return { instance, module };
        } else {
            return instance;
        }
    }

    function expectedResponseType(type) {
        switch (type) {
            case 'basic': case 'cors': case 'default': return true;
        }
        return false;
    }
}

function initSync(module) {
    if (wasm !== undefined) return wasm;


    if (module !== undefined) {
        if (Object.getPrototypeOf(module) === Object.prototype) {
            ({module} = module)
        } else {
            console.warn('using deprecated parameters for `initSync()`; pass a single object instead')
        }
    }

    const imports = __wbg_get_imports();
    if (!(module instanceof WebAssembly.Module)) {
        module = new WebAssembly.Module(module);
    }
    const instance = new WebAssembly.Instance(module, imports);
    return __wbg_finalize_init(instance, module);
}

let __wbg_init_promise;
async function __wbg_init(module_or_path) {
    if (wasm !== undefined) return wasm;
    if (__wbg_init_promise === undefined) {
        __wbg_init_promise = __wbg_init_once(module_or_path);
        __wbg_init_promise.catch(() => { __wbg_init_promise = undefined; });
    }
    return __wbg_init_promise;
}

async function __wbg_init_once(module_or_path) {

    if (module_or_path !== undefined) {
        if (Object.getPrototypeOf(module_or_path) === Object.prototype) {
            ({module_or_path} = module_or_path)
        } else {
            console.warn('using deprecated parameters for the initialization function; pass a single object instead')
        }
    }

    if (module_or_path === undefined) {
        module_or_path = new URL('s02sim_bg.wasm', import.meta.url);
    }
    const imports = __wbg_get_imports();

    if (typeof module_or_path === 'string' || (typeof Request === 'function' && module_or_path instanceof Request) || (typeof URL === 'function' && module_or_path instanceof URL)) {
        module_or_path = fetch(module_or_path);
    }

    const { instance, module } = await __wbg_load(await module_or_path, imports);

    return __wbg_finalize_init(instance, module);
}

export { initSync, __wbg_init as default };
