#include <zectrix_native_display.h>

#ifdef BOARD_ZECTRIX_NATIVE_EPD

#include <Arduino.h>
#include <SPI.h>
#include <board_config.h>
#include <epd_driver.h>
#include <globals.h>
#include <trmnl_log.h>

#include <cstddef>

namespace {

constexpr size_t kWidth = 400;
constexpr size_t kHeight = 300;
constexpr size_t kRowBytes = kWidth / 4;
constexpr uint32_t kSpiHz = 40000000;

SPIClass note_spi(HSPI);

void write_command(uint8_t command) {
  digitalWrite(pDevice->epd_dc_pin, LOW);
  digitalWrite(pDevice->epd_cs_pin, LOW);
  note_spi.transfer(command);
  digitalWrite(pDevice->epd_cs_pin, HIGH);
}

void write_data(const uint8_t *data, size_t length) {
  digitalWrite(pDevice->epd_dc_pin, HIGH);
  digitalWrite(pDevice->epd_cs_pin, LOW);
  note_spi.transferBytes(data, nullptr, length);
  digitalWrite(pDevice->epd_cs_pin, HIGH);
}

void write_data(uint8_t value) { write_data(&value, 1); }

bool wait_idle(const char *stage, uint32_t timeout_ms) {
  const uint32_t started_at = millis();
  while (digitalRead(pDevice->epd_busy_pin) == LOW) {
    if (millis() - started_at >= timeout_ms) {
      Log_error("EPD busy timeout: stage=%s gpio=%u level=%d elapsed_ms=%lu", stage,
                pDevice->epd_busy_pin, digitalRead(pDevice->epd_busy_pin), millis() - started_at);
      return false;
    }
    delay(1);
  }
  return true;
}

} // namespace

void zectrix_native_display_init() {
  if (pDevice == nullptr) {
    Log_fatal("ZecTrix display initialized without a board configuration");
    return;
  }
  const uint32_t panel_type = dpList[pDevice->panel_set][iTempProfile].TwoBit;
  bbep.setPanelType(panel_type);
  if (bbep.width() != kWidth || bbep.height() != kHeight) {
    Log_error("Unexpected ZecTrix framebuffer dimensions: %u x %u", bbep.width(), bbep.height());
  }

  // The SSD2683 is driven by the board-specific command sequence below, not
  // bb_epaper's generic GDEM042F52 initialization callbacks.
  const auto *init_full = bbep._bbep.pInitFull;
  const auto *init_fast = bbep._bbep.pInitFast;
  const auto *init_part = bbep._bbep.pInitPart;
  bbep._bbep.pInitFull = nullptr;
  bbep._bbep.pInitFast = nullptr;
  bbep._bbep.pInitPart = nullptr;
  bbep.initIO(pDevice->epd_dc_pin, pDevice->epd_rst_pin, pDevice->epd_busy_pin, pDevice->epd_cs_pin,
              pDevice->epd_mosi_pin, pDevice->epd_sck_pin, kSpiHz);
  bbep._bbep.pInitFull = init_full;
  bbep._bbep.pInitFast = init_fast;
  bbep._bbep.pInitPart = init_part;

  pinMode(pDevice->epd_cs_pin, OUTPUT);
  pinMode(pDevice->epd_dc_pin, OUTPUT);
  digitalWrite(pDevice->epd_cs_pin, HIGH);
  note_spi.begin(pDevice->epd_sck_pin, -1, pDevice->epd_mosi_pin, -1);
}

bool zectrix_native_display_update() {
  if (pDevice == nullptr) return false;
  auto *buffer = static_cast<uint8_t *>(bbep.getBuffer());
  if (buffer == nullptr) {
    Log_error("ZecTrix EPD update has no framebuffer");
    return false;
  }

  digitalWrite(pDevice->epd_en_pin, HIGH);
  digitalWrite(pDevice->epd_cs_pin, HIGH);
  delay(10);
  digitalWrite(pDevice->epd_rst_pin, HIGH);
  delay(10);
  digitalWrite(pDevice->epd_rst_pin, LOW);
  delay(20);
  digitalWrite(pDevice->epd_rst_pin, HIGH);
  delay(10);
  if (!wait_idle("reset", 60000)) {
    digitalWrite(pDevice->epd_en_pin, LOW);
    return false;
  }

  note_spi.beginTransaction(SPISettings(
#ifdef BOARD_ZECTRIX_NOTE4
    8000000,
#else
    kSpiHz,
#endif
    MSBFIRST, SPI_MODE0));

#ifdef BOARD_ZECTRIX_NOTE4
  // Select the Note 4 black/white OTP waveform and use the reference driver's
  // 25 C fallback temperature.
  write_command(0x00);
  write_data(0x2f);
  write_data(0x0e);
#endif
  write_command(0xe9);
  write_data(0x01);

#ifdef BOARD_ZECTRIX_NOTE4
  if (!wait_idle("otp_init", 10000)) goto failed;
  write_command(0x40);
  if (!wait_idle("temperature_read", 10000)) goto failed;
  write_command(0xe0);
  write_data(0x02);
  write_command(0xe6);
  write_data(241);
  write_command(0xa5);
  if (!wait_idle("temperature_activate", 10000)) goto failed;
  delay(10);
#endif

  write_command(0x10);
  if (!wait_idle("image_write", 60000)) goto failed;
  for (size_t row = 0; row < kHeight; ++row) {
    write_data(buffer + row * kRowBytes, kRowBytes);
    if ((row % 16) == 15) delay(1);
  }

  write_command(0x04);
  if (!wait_idle("power_on", 60000)) goto failed;
  delay(10);
  write_command(0x12);
  write_data(0x00);
  delay(10);
  if (!wait_idle("display_refresh", 180000)) goto failed;

  write_command(0x02);
  write_data(0x00);
  if (!wait_idle("controller_power_off", 60000)) goto failed;

  delay(20);
  write_command(0x07);
  write_data(0xa5);
  digitalWrite(pDevice->epd_cs_pin, HIGH);
  note_spi.endTransaction();
  digitalWrite(pDevice->epd_en_pin, LOW);
  return true;

failed:
  digitalWrite(pDevice->epd_cs_pin, HIGH);
  note_spi.endTransaction();
  digitalWrite(pDevice->epd_en_pin, LOW);
  return false;
}

void zectrix_native_display_sleep() {
  if (pDevice != nullptr) digitalWrite(pDevice->epd_en_pin, LOW);
}

#endif // BOARD_ZECTRIX_NATIVE_EPD
