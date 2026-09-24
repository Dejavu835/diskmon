#include <DiskMonIOKitSMART.h>

#include <IOKit/IOCFPlugIn.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/storage/IOBlockStorageDevice.h>
#include <IOKit/storage/ata/ATASMARTLib.h>
#include <string.h>
#include <stdlib.h>

#define MISSING INT32_MIN

static const CFUUIDBytes kNVMeSMARTUserClientType = {
    0xAA, 0x0F, 0xA6, 0xF9, 0xC2, 0xD6, 0x45, 0x7F,
    0xB1, 0x0B, 0x59, 0xA1, 0x32, 0x53, 0x29, 0x2F
};
static const CFUUIDBytes kNVMeSMARTInterface = {
    0xCC, 0xD1, 0xDB, 0x19, 0xFD, 0x9A, 0x4D, 0xAF,
    0xBF, 0x95, 0x12, 0x45, 0x4B, 0x23, 0x0A, 0xB6
};

/* NVMe Log Page 0x02 is exactly 512 bytes. Undersizing this smashed the stack (SIGABRT). */

typedef struct IONVMeSMARTInterface {
    IUNKNOWN_C_GUTS;
    UInt16 version;
    UInt16 revision;
    IOReturn (*SMARTReadData)(void *interface, void *NVMeSMARTData);
} IONVMeSMARTInterface;

static void initOut(DiskMonNativeSMART *out) {
    memset(out, 0, sizeof(*out));
    out->celsius = MISSING;
    out->percentUsed = MISSING;
    out->availableSpare = MISSING;
    out->powerOnHours = MISSING;
    out->powerCycles = MISSING;
    out->unsafeShutdowns = MISSING;
    out->mediaErrors = MISSING;
    out->criticalWarning = MISSING;
    out->dataUnitsReadTB = -1;
    out->dataUnitsWrittenTB = -1;
    out->healthPassed = -1;
}

static io_object_t blockStorageForBSD(const char *bsdName) {
    if (!bsdName || !bsdName[0]) return 0;
    const char *name = bsdName;
    if (strncmp(name, "/dev/", 5) == 0) name += 5;
    io_object_t disk = IOServiceGetMatchingService(kIOMainPortDefault,
                                                   IOBSDNameMatching(kIOMainPortDefault, 0, name));
    if (!disk) return 0;
    while (IOObjectConformsTo(disk, kIOBlockStorageDeviceClass) == 0) {
        io_registry_entry_t parent = 0;
        if (IORegistryEntryGetParentEntry(disk, kIOServicePlane, &parent) != KERN_SUCCESS || parent == 0) {
            IOObjectRelease(disk);
            return 0;
        }
        IOObjectRelease(disk);
        disk = parent;
    }
    return disk;
}

static uint64_t le_u64_16(const UInt8 *b) {
    uint64_t v = 0;
    for (int i = 7; i >= 0; i--) {
        v = (v << 8) | b[i];
    }
    return v;
}

static int32_t kelvinToC(uint16_t k) {
    int c = (int)k - 273;
    if (c < -20 || c > 120) return MISSING;
    return (int32_t)c;
}

bool DiskMonReadNVMeSMART(const char *bsdName, DiskMonNativeSMART *out) {
    if (!out) return false;
    initOut(out);
    io_object_t disk = blockStorageForBSD(bsdName);
    if (!disk) return false;

    CFTypeRef raw = IORegistryEntryCreateCFProperty(disk, CFSTR("NVMe SMART Capable"),
                                                    kCFAllocatorDefault, 0);
    bool capable = false;
    if (raw) {
        if (CFGetTypeID(raw) == CFBooleanGetTypeID()) {
            capable = CFBooleanGetValue((CFBooleanRef)raw);
        }
        CFRelease(raw);
    }
    if (!capable) {
        IOObjectRelease(disk);
        return false;
    }

    CFUUIDRef typeID = CFUUIDCreateFromUUIDBytes(kCFAllocatorDefault, kNVMeSMARTUserClientType);
    CFUUIDRef ifaceID = CFUUIDCreateFromUUIDBytes(kCFAllocatorDefault, kNVMeSMARTInterface);
    IOCFPlugInInterface **plugin = NULL;
    SInt32 score = 0;
    IOReturn kr = IOCreatePlugInInterfaceForService(disk, typeID, kIOCFPlugInInterfaceID, &plugin, &score);
    CFRelease(typeID);
    IOObjectRelease(disk);
    if (kr != kIOReturnSuccess || !plugin) {
        CFRelease(ifaceID);
        return false;
    }

    IONVMeSMARTInterface **smart = NULL;
    kr = (*plugin)->QueryInterface(plugin, CFUUIDGetUUIDBytes(ifaceID), (LPVOID)&smart);
    CFRelease(ifaceID);
    if (kr != kIOReturnSuccess || !smart) {
        IODestroyPlugInInterface(plugin);
        return false;
    }

    uint8_t log[512];
    memset(log, 0, sizeof(log));
    kr = (*smart)->SMARTReadData(smart, log);
    (*smart)->Release(smart);
    IODestroyPlugInInterface(plugin);
    if (kr != kIOReturnSuccess) return false;

    uint16_t kelvin = (uint16_t)log[1] | ((uint16_t)log[2] << 8);
    out->celsius = kelvinToC(kelvin);
    out->percentUsed = log[5];
    out->availableSpare = log[3];
    out->criticalWarning = log[0];
    out->powerOnHours = (int32_t)le_u64_16(log + 128);
    out->powerCycles = (int32_t)le_u64_16(log + 112);
    out->unsafeShutdowns = (int32_t)le_u64_16(log + 144);
    out->mediaErrors = (int32_t)le_u64_16(log + 160);
    out->dataUnitsReadTB = (double)le_u64_16(log + 32) * 512000.0 / 1e12;
    out->dataUnitsWrittenTB = (double)le_u64_16(log + 48) * 512000.0 / 1e12;
    out->healthPassed = (log[0] == 0) ? 1 : 0;
    return true;
}

bool DiskMonReadATASMART(const char *bsdName, DiskMonNativeSMART *out) {
    if (!out) return false;
    initOut(out);
    io_object_t disk = blockStorageForBSD(bsdName);
    if (!disk) return false;

    CFTypeRef raw = IORegistryEntryCreateCFProperty(disk, CFSTR("SMART Capable"),
                                                    kCFAllocatorDefault, 0);
    bool capable = false;
    if (raw) {
        if (CFGetTypeID(raw) == CFBooleanGetTypeID()) {
            capable = CFBooleanGetValue((CFBooleanRef)raw);
        }
        CFRelease(raw);
    }
    if (!capable) {
        IOObjectRelease(disk);
        return false;
    }

    IOCFPlugInInterface **plugin = NULL;
    SInt32 score = 0;
    IOReturn kr = IOCreatePlugInInterfaceForService(disk, kIOATASMARTUserClientTypeID,
                                                    kIOCFPlugInInterfaceID, &plugin, &score);
    IOObjectRelease(disk);
    if (kr != kIOReturnSuccess || !plugin) return false;

    IOATASMARTInterface **smart = NULL;
    kr = (*plugin)->QueryInterface(plugin, CFUUIDGetUUIDBytes(kIOATASMARTInterfaceID), (LPVOID)&smart);
    if (kr != kIOReturnSuccess || !smart) {
        IODestroyPlugInInterface(plugin);
        return false;
    }

    ATASMARTData data;
    memset(&data, 0, sizeof(data));
    kr = (*smart)->SMARTReadData(smart, &data);
    if (kr != kIOReturnSuccess) {
        (*smart)->SMARTEnableDisableOperations(smart, true);
        kr = (*smart)->SMARTReadData(smart, &data);
    }
    (*smart)->Release(smart);
    IODestroyPlugInInterface(plugin);
    if (kr != kIOReturnSuccess) return false;

    const UInt8 *bytes = (const UInt8 *)&data;
    // vendor attributes start at offset 2, 12 bytes each, 30 slots
    int32_t temp = MISSING;
    int32_t poh = MISSING;
    int32_t cycles = MISSING;
    for (int i = 0; i < 30; i++) {
        int off = 2 + i * 12;
        UInt8 id = bytes[off];
        if (id == 0) continue;
        UInt8 raw0 = bytes[off + 5];
        uint32_t raw32 = (uint32_t)bytes[off + 5]
            | ((uint32_t)bytes[off + 6] << 8)
            | ((uint32_t)bytes[off + 7] << 16)
            | ((uint32_t)bytes[off + 8] << 24);
        if ((id == 194 || id == 190) && temp == MISSING) {
            temp = raw0;
        }
        if (id == 9) poh = (int32_t)raw32;
        if (id == 12) cycles = (int32_t)raw32;
    }
    if (temp == MISSING && poh == MISSING) return false;
    out->celsius = temp;
    out->powerOnHours = poh;
    out->powerCycles = cycles;
    out->healthPassed = 1;
    return true;
}
