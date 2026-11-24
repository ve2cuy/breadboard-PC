/* RP2040 du Pico W : 2 Mo de flash (le dernier secteur de 4 Ko garde le reglage du Wi-Fi), 264 Ko de RAM */
MEMORY {
    BOOT2 : ORIGIN = 0x10000000, LENGTH = 0x100
    FLASH : ORIGIN = 0x10000100, LENGTH = 2048K - 0x100 - 4K
    RAM   : ORIGIN = 0x20000000, LENGTH = 264K
}
