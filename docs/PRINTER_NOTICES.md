# Printer Notices

HMS notices resolve offline using `lib/bambu_hms_catalog.g.dart`. The catalog
contains 5,222 nonempty descriptions imported from the MIT-licensed bambulan
catalog at commit `213d9f5ffc98a1656afdb2c9967e4612229c46c3`. Its license is
preserved in the generated source and registered with Flutter's license registry.
Printer-provided HMS text takes precedence over the catalog.

Regenerate from a local bambulan checkout:

```sh
go run tools/import_hms_catalog.go \
  -source /path/to/bambulan/internal/hms/codes_generated.go
fvm dart format lib/bambu_hms_catalog.g.dart
```

MQTT `attr` identifies the component and `code` contains the severity and
condition. The catalog key is the eight-digit hexadecimal `attr` followed by the
eight-digit `code`, matching Bambu Studio's
[DevHMS implementation](https://github.com/bambulab/BambuStudio/blob/master/src/slic3r/GUI/DeviceCore/DevHMS.cpp).
The old BoomPrint implementation reversed these fields.

For example, `attr=0x05000100, code=0x00030004` is
`0500-0100-0003-0004`: full removable storage. BoomPrint retains its MicroSD
description and presents this as an informational notice. Other HMS conditions
use the reported severity: fatal/serious errors are red, common warnings use a
warning color, and informational notices use a neutral background.

Dismissal affects the local UI only. It does not acknowledge or clear errors on
the printer. Each condition stays dismissed across telemetry updates and report
reordering until the printer reports it cleared. A later recurrence is shown
again. Print errors remain visible alongside storage notices. The copy action
includes both description and code.

Unknown HMS conditions explicitly report that no description is available.
The separate, shorter `print_error` namespace is not looked up in the HMS
catalog: it uses printer-supplied text when present and an explanatory fallback
otherwise. No network lookup or guessed wiki link is needed to show a notice.

## Related Upstream Finding

In bambulan commit `213d9f5ffc98a1656afdb2c9967e4612229c46c3`,
`HMSEvent` maps `Attr` and `Code` directly from JSON, but the helpers in
`internal/hms/codes_generated.go` build the full key as `code << 32 | attr`.
This also affects its displayed codes and wiki links. This app imports only the
description table, not those helpers.

Minimal reproduction without a printer:

```text
MQTT event: {"attr": 50331904, "code": 65539}
            attr=0x03000100, code=0x00010003
Expected catalog key: 0300010000010003 (heatbed over-temperature)
Current bambulan Lookup(event.Code, event.Attr) key: 0001000303000100
Observed: no description, despite an existing catalog entry.
```

A GitHub issue search for HMS on 2026-11-05 found no matching report. Recommend
an upstream issue and focused fix to normalize the MQTT fields at the event
boundary, with tests using actual JSON ordering. Standalone helpers and callers
must agree on their parameter order; the description table does not need changing.

Regression coverage is in `test/bambu_mqtt_status_test.dart` and
`test/stream_page_widgets_test.dart`, including full-card telemetry, dismissal
and recurrence, simultaneous print errors, unknown conditions, copying, and a
320-pixel layout. These tests do not connect to a printer or send commands.
