import 'package:boomprint/bambu_lan.dart';
import 'package:boomprint/bambu_mqtt.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mqtt_client/mqtt_client.dart';

class RecordingMqtt extends BambuMqtt {
  RecordingMqtt()
    : super(
        const BambuLanConfig(
          printerIp: '192.0.2.1',
          accessCode: 'test',
          serial: 'test',
        ),
      );

  Map<String, dynamic>? request;

  @override
  Future<void> publishRequest(
    Map<String, dynamic> payload, {
    MqttQos qos = MqttQos.atMostOnce,
  }) async {
    request = payload;
  }
}

void main() {
  test('project preparation choices reach the printer payload', () async {
    final mqtt = RecordingMqtt();
    await mqtt.printProjectFile(
      projectPath: '/model.3mf',
      timelapse: false,
      bedLevelling: true,
      flowCalibration: false,
      vibrationCalibration: false,
      layerInspection: false,
      useAms: false,
    );
    final print = mqtt.request!['print'] as Map;
    expect(print['timelapse'], false);
    expect(print['bed_levelling'], true);
    expect(print['flow_cali'], false);
    expect(print['vibration_cali'], false);
    expect(print['layer_inspect'], false);
    expect(print['use_ams'], false);
    expect(print['url'], 'file:///sdcard/model.3mf');
  });

  test('existing callers retain preparation defaults', () async {
    final mqtt = RecordingMqtt();
    await mqtt.printProjectFile(projectPath: '/model.3mf');
    final print = mqtt.request!['print'] as Map;
    for (final key in [
      'timelapse',
      'bed_levelling',
      'flow_cali',
      'vibration_cali',
      'layer_inspect',
    ]) {
      expect(print[key], true, reason: key);
    }
  });
}
