# HeyMelody earbuds protocol: notes from OnePlus Buds 3

These notes come from talking to a OnePlus Buds 3 from macOS. Each command listed under "Verified" was sent to the buds and its reply was checked. Other models in the OPPO / OnePlus / realme family share the framing, but their mode bits and IDs may differ.

## Transport

- Bluetooth Classic RFCOMM. The SDP service is named **"enco link"**, UUID `0000079a-d102-11e1-9b23-00025b00a5a5` (channel 15 on Buds 3).
- Only **one** control connection is accepted at a time.
- Right after the channel opens, the buds push a host-list notification (`0x0204`). Commands sent during that burst are dropped, so wait about 1 s before sending.

## Frame

```
AA <len varint> 00 00 <cmd u16le> <seq u8> <paylen u16le> <payload>
```

- `len` counts everything after it: the `00 00`, the 5-byte header and the payload.
- Replies use the same `cmd` with bit 15 set (`0x0106` → `0x8106`). `payload[0]` is a status byte: `00` means OK.
- Command ranges: `0x01xx` get, `0x04xx` set, `0x02xx` notifications from the buds.

## Verified

| Cmd | Payload | Reply payload | Meaning |
|---|---|---|---|
| `0x0106` | none | `00 <n> (<idx> <val>)×n` | Battery. idx 1 = left, 2 = right, 3 = case. Low 7 bits of val = %, bit 7 = charging |
| `0x010C` | `01 01` | `00 01 01 <bitmap u16le>` | Current noise mode (lowest set bit) |
| `0x010C` | `04 01` | `00 04 01 <bitmap u16le>` | Strength the Adaptive mode is currently using |
| `0x010C` | `02 01` | `00 02 01 <bitmap u16le>` | Supported top-level modes (`0x0006` on Buds 3) |
| `0x0404` | `01 01 <bitmap u16le>` | `00` | Set noise mode. Returns status `0E` unless **both buds are worn** |
| `0x0109` | none | `00 <n> (<idx> <flags>)×n` | Wear: idx 1 = L, 2 = R, 3 = case. flags `0x02` = in ear, `0x01` clear = in case |
| `0x010F` | none | `00 <id>` | Current EQ (preset ID or custom slot ID) |
| `0x0406` | `<id>` | `00` | Select EQ preset |
| `0x0122` | none | see below | List custom EQ slots |
| `0x0418` | see below | `00 <id>` | Create / save+select / delete custom EQ |

### Noise mode bits (Buds 3)

| Bit | Mode |
|---|---|
| 0 / 1 / 2 | Shortcuts: setting them lands on bit 3 / 4 / 9 |
| 3 | Off |
| 4 | Max |
| 5 | Moderate |
| 6 | Mild |
| 7 | Adaptive ("Smart Scene"). `0x010C 04 01` reports which strength (bit 4–6) it is using |
| 8 | Accepted, purpose unknown (transparency on other models) |
| 9 | Transparency |

### EQ

Presets on Buds 3: `0` Balanced, `1` Bold, `2` Serenade, `3` Bass. Custom slots use IDs 4 and up.

Each custom slot, both in the `0x0122` reply (after `00 <count>`) and in the `0x0418` payload (after `<op>`):

```
<selected/op> <min s8> <max s8> <id> <nameLen> <name utf8> <n> (<freq u16le> <dB s8>)×n
```

- Buds 3 uses 6 bands at 62 / 250 / 1000 / 4000 / 8000 / 16000 Hz, with a range of −6 to +6 dB.
- `op`: `1` create (id 0), `2` save values and select, `3` delete.
- On Buds 3, op 2 leaves a single custom slot in the list.

Live wear changes arrive as notification `0x0204` with payload `02 ?? 01 <L> 02 <R> 03 <case>`. This layout comes from another implementation and has not yet been observed on Buds 3.

The 4–7 order matches a Buds 4 / Buds Pro 3 implementation (`0x10` High, `0x20` Moderate, `0x40` Low, `0x80` Auto) and Buds 3 behaviour; it has not been confirmed by ear.

## Seen but not used by BudsDeck

`0x0108` gesture map, `0x0105` firmware versions, `0x0112` connected hosts, `0x0124` BassWave level (`min max value`). The buds also push unsolicited diagnostic JSON, for example `{"cmd":"sco_caton",…}`.
