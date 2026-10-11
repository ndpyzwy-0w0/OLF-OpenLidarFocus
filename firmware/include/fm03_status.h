// Read-only whole-frame DUML state decoder, shared by listener/control builds.
// No driver, serial, dynamic allocation or transmit calls. Only 0x504 BF>E5
// flags=00 04:2F payload=09 00 (28 bytes) publishes coordinates.
#pragma once
#include <stdint.h>
#include <string.h>
#include <limits.h>

class MotorStatusDecoder {
public:
    uint32_t epoch = 0;
    uint32_t packets = 0;
    int stage = -1;
    int32_t coordinate = 0;
    int64_t sample_us = 0;
    bool updated = false;

    bool valid() const {
        return stage == 3 && coordinate != INT32_MIN && coordinate != INT32_MAX;
    }

    void reset() {
        used = 0;
        stage = -1;
        coordinate = 0;
        sample_us = 0;
        ++epoch;
        updated = true;
    }

    void feed(uint32_t id, bool extended, bool rtr, const uint8_t *data,
              unsigned length, int64_t stamp) {
        if (id != 0x504 || extended || rtr || !length || length > 8) return;
        if (used && (stamp < frames[used-1].stamp || stamp-frames[used-1].stamp > 300000)) reset();
        if (used == 32) reset();
        Frame &frame = frames[used++];
        frame.stamp = stamp;
        frame.length = length;
        memcpy(frame.data,data,length);
        while (used) {
            const Frame &first = frames[0];
            unsigned target = first.length >= 4 ? first.data[1] | ((first.data[2]&3)<<8) : 0;
            if (first.length < 4 || first.data[0] != 0x55 || target < 13 || target > 128 ||
                    checksum(first.data,3,0x77,0x8c) != first.data[3]) {
                drop(1);
                continue;
            }
            uint8_t packet[128];
            unsigned bytes = 0, count = 0;
            while (count < used && bytes < target) {
                if (bytes+frames[count].length > sizeof(packet)) break;
                memcpy(packet+bytes,frames[count].data,frames[count].length);
                bytes += frames[count++].length;
            }
            if (bytes < target && count == used) break;
            if (bytes != target || checksum(packet,target-2,0x3692,0x8408) !=
                    (uint16_t)(packet[target-2] | (packet[target-1]<<8))) {
                // Reconsider every following whole frame; a continuation starting
                // with 55 is never assumed to begin a new packet before CRC check.
                drop(1);
                continue;
            }
            if (target == 28 && packet[4] == 0xbf && packet[5] == 0xe5 &&
                    packet[8] == 0 && packet[9] == 4 && packet[10] == 0x2f &&
                    packet[11] == 9 && packet[12] == 0) {
                stage = packet[13];
                uint32_t raw = (uint32_t)packet[14] | ((uint32_t)packet[15]<<8) |
                              ((uint32_t)packet[16]<<16) | ((uint32_t)packet[17]<<24);
                memcpy(&coordinate,&raw,sizeof(raw));
                sample_us = first.stamp;
                ++packets;
                updated = true;
            }
            drop(count);
        }
    }

private:
    struct Frame { int64_t stamp; unsigned length; uint8_t data[8]; };
    Frame frames[32]{};
    unsigned used = 0;

    void drop(unsigned count) {
        if (count < used) memmove(frames,frames+count,(used-count)*sizeof(Frame));
        used -= count;
    }

    static uint16_t checksum(const uint8_t *data, unsigned length,
                             uint16_t value, uint16_t polynomial) {
        for (unsigned i=0; i<length; ++i) {
            value ^= data[i];
            for (unsigned bit=0; bit<8; ++bit)
                value = (value&1) ? (value>>1)^polynomial : value>>1;
        }
        return value;
    }
};
