import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:p2l_tester/models/p2l_led_config.dart';
import 'package:p2l_tester/services/command_service.dart';

void main() {
  group('P2lLedConfig.fromGetConfig', () {
    test('parsuje jas, počty LED na portech a barvy', () {
      final cfg = P2lLedConfig.fromGetConfig(<String, dynamic>{
        'brightness': 50,
        'leds port0': 60,
        'leds port1': 120,
        'color0': 'ff0000',
        'color2_0': '00ff00',
        'color3': '112233',
      });

      expect(cfg.brightness, 50);
      expect(cfg.ledCountOf(0), 60);
      expect(cfg.ledCountOf(1), 120);
      expect(cfg.ledCountOf(2), isNull);
      expect(cfg.maxLedCount, 120);
      expect(cfg.colorOf(0).rgb, 0xFF0000);
      expect(cfg.colorOf(0).rgb2, 0x00FF00);
      expect(cfg.colorOf(3).rgb, 0x112233);
      expect(cfg.isLoaded, isTrue);
    });

    test('chybějící color2 doplní tovární hodnotou slotu', () {
      // Firmware nemusí poslat všechno; slot se nesmí rozsypat na 0x000000.
      final cfg = P2lLedConfig.fromGetConfig(<String, dynamic>{
        'color2': '0000ff',
      });
      expect(cfg.colorOf(2).rgb, 0x0000FF);
      expect(cfg.colorOf(2).rgb2, kP2lDefaultColors[2].rgb2); // YELLOW
    });

    test('nenačtená konfigurace vrací tovární barvy a není isLoaded', () {
      const cfg = P2lLedConfig.empty;
      expect(cfg.isLoaded, isFalse);
      expect(cfg.colorOf(1).rgb, 0x00FF00); // GREEN
      expect(cfg.maxLedCount, 0);
    });

    test('hex s mřížkou i číselná hodnota barvy', () {
      final cfg = P2lLedConfig.fromGetConfig(<String, dynamic>{
        'color0': '#ABCDEF',
        'color1': 255,
      });
      expect(cfg.colorOf(0).rgb, 0xABCDEF);
      expect(cfg.colorOf(1).rgb, 0x0000FF);
    });

    test('reálná odpověď jednotky 1209 — deset barevných slotů', () {
      // Zkrácený, ale tvarem věrný payload z GET-CONFIG (FW 26071501NT).
      final cfg = P2lLedConfig.fromGetConfig(<String, dynamic>{
        'brightness': 20,
        for (int p = 0; p < 8; p++) 'leds port$p': 599,
        'color0': 'ff0000',
        'color2_0': '00ff00',
        'color1': '00ff00',
        'color2_1': 'ff0000',
        'color2': '0000ff',
        'color2_2': 'aa5500',
        'color3': 'aa5500',
        'color2_3': '0000ff',
        'color4': 'aa0055',
        'color2_4': '555555',
        'color5': '555555',
        'color2_5': 'aa0055',
        'color6': '000000',
        'color2_6': '000000',
        'color7': '000000',
        'color2_7': '000000',
        'color8': '000000',
        'color2_8': '000000',
        'color9': '000000',
        'color2_9': '000000',
      });

      expect(cfg.brightness, 20);
      expect(cfg.ledCounts.length, 8);
      expect(cfg.ledCountOf(7), 599);
      // Past: klíč `color2` je barva slotu 2, ne „color2" slotu 0 —
      // regexy se nesmí přebít.
      expect(cfg.colorOf(2).rgb, 0x0000FF);
      expect(cfg.colorOf(0).rgb2, 0x00FF00);
      // Slotů je deset, ne šest.
      expect(cfg.colors.length, kP2lColorCount);
      expect(cfg.colorOf(9).rgb, 0x000000);
    });

    test('chyba (Code/Message) nezpůsobí pád parseru', () {
      final cfg = P2lLedConfig.fromGetConfig(<String, dynamic>{
        'Code': -2,
        'Message': 'unknown ID',
      });
      expect(cfg.brightness, isNull);
      expect(cfg.ledCounts, isEmpty);
    });
  });

  group('P2L LED příkazy — nový protokol (FW >= P2L_26071501NT)', () {
    test('GET-CONFIG topic P2L, ne UNIT', () {
      final cmd = CommandService.buildP2lGetConfigCommand('1209');
      expect(cmd.topic, 'I/001209/P2L/011209/GET-CONFIG');
      expect(cmd.payload, '{}');
      // Nesmí kolidovat s UNIT GET-CONFIG (síťová konfigurace jednotky).
      expect(
        cmd.topic,
        isNot(CommandService.buildGetConfigCommand('1209').topic),
      );
    });

    test('SET-LEDS: pole bloků, jeden na port', () {
      final cmd = CommandService.buildP2lSetLedsCommand(
        unitId: '1209',
        ports: [0, 3],
        x1: 0,
        x2: 59,
        styleId: 1,
        colorId: 2,
        newProtocol: true,
      );
      expect(cmd.topic, 'I/001209/P2L/011209/SET-LEDS');
      final payload = jsonDecode(cmd.payload) as List;
      expect(payload, hasLength(2));
      expect(payload[0], {
        'port': 0,
        'x1': 0,
        'x2': 59,
        'style_id': 1,
        'color_id': 2,
      });
      expect((payload[1] as Map)['port'], 3);
    });

    test('CLR-STRIPS bez portů = všechny (prázdný payload)', () {
      final cmd = CommandService.buildP2lClearStripsCommand(
        unitId: '1209',
        newProtocol: true,
      );
      expect(cmd.topic, 'I/001209/P2L/011209/CLR-STRIPS');
      expect(cmd.payload, '{}');
    });

    test('CLR-STRIPS s porty', () {
      final cmd = CommandService.buildP2lClearStripsCommand(
        unitId: '1209',
        ports: [0, 1],
        newProtocol: true,
      );
      expect(jsonDecode(cmd.payload), {
        'ports': [0, 1],
      });
    });

    test('jas jde na SET-CONFIG a ořízne se do 1–100', () {
      final cmd = CommandService.buildP2lBrightnessCommand(
        unitId: '1209',
        brightness: 250,
        newProtocol: true,
      );
      expect(cmd.topic, 'I/001209/P2L/011209/SET-CONFIG');
      expect(jsonDecode(cmd.payload), {'brightness': 100});

      final low = CommandService.buildP2lBrightnessCommand(
        unitId: '1209',
        brightness: 0,
        newProtocol: true,
      );
      expect(jsonDecode(low.payload), {'brightness': 1});
    });

    test('počty LED: všechny porty v jednom SET-CONFIG, seřazené', () {
      final cmd = CommandService.buildP2lLedCountsCommand(
        unitId: '1209',
        counts: {3: 90, 0: 60},
        newProtocol: true,
      );
      expect(cmd.topic, 'I/001209/P2L/011209/SET-CONFIG');
      expect(jsonDecode(cmd.payload), {
        'ledCounts': [
          {'port': 0, 'leds': 60},
          {'port': 3, 'leds': 90},
        ],
      });
    });

    test('barvy: rozpad RGB i RGB2 na složky', () {
      final cmd = CommandService.buildP2lColorsCommand(
        unitId: '1209',
        colors: {4: const P2lColorSlot(0x805400, 0x00FF00)},
        newProtocol: true,
      );
      expect(cmd.topic, 'I/001209/P2L/011209/SET-CONFIG');
      expect(jsonDecode(cmd.payload), {
        'colors': [
          {
            'color_id': 4,
            'red': 128,
            'green': 84,
            'blue': 0,
            'red2': 0,
            'green2': 255,
            'blue2': 0,
          },
        ],
      });
    });
  });

  group('P2L LED příkazy — starý CMD formát', () {
    test('SET-LEDS se pošle jako cmds na CMD topic', () {
      final cmd = CommandService.buildP2lSetLedsCommand(
        unitId: '0472',
        ports: [0],
        x1: 0,
        x2: 9,
        styleId: 0,
        colorId: 1,
        newProtocol: false,
        isNewGen: false,
      );
      expect(cmd.topic, 'I/u0472/SERVER/CMD');
      final payload = jsonDecode(cmd.payload) as Map<String, dynamic>;
      expect(payload['request_id'], -1);
      expect(payload['cmds'], [
        {
          'cmd': 'set_leds',
          'args': {'port': 0, 'x1': 0, 'x2': 9, 'style_id': 0, 'color_id': 1},
        },
      ]);
    });

    test('jas přes set_brightness', () {
      final cmd = CommandService.buildP2lBrightnessCommand(
        unitId: '0472',
        brightness: 30,
        newProtocol: false,
        isNewGen: false,
      );
      expect(cmd.topic, 'I/u0472/SERVER/CMD');
      expect((jsonDecode(cmd.payload) as Map)['cmds'], [
        {
          'cmd': 'set_brightness',
          'args': {'value': 30},
        },
      ]);
    });

    test('počty LED přes set_led_count, jeden příkaz na port', () {
      final cmd = CommandService.buildP2lLedCountsCommand(
        unitId: '0472',
        counts: {0: 60, 1: 60},
        newProtocol: false,
        isNewGen: false,
      );
      final cmds = (jsonDecode(cmd.payload) as Map)['cmds'] as List;
      expect(cmds, hasLength(2));
      expect(cmds.first, {
        'cmd': 'set_led_count',
        'args': {'port': 0, 'leds': 60},
      });
    });

    test('barvy přes set_color', () {
      final cmd = CommandService.buildP2lColorsCommand(
        unitId: '0472',
        colors: {0: const P2lColorSlot(0xFF0000, 0x00FF00)},
        newProtocol: false,
        isNewGen: false,
      );
      final cmds = (jsonDecode(cmd.payload) as Map)['cmds'] as List;
      expect((cmds.first as Map)['cmd'], 'set_color');
      expect((cmds.first as Map)['args'], {
        'color_id': 0,
        'red': 255,
        'green': 0,
        'blue': 0,
        'red2': 0,
        'green2': 255,
        'blue2': 0,
      });
    });

    test('CLR-STRIPS bez portů vynechá args', () {
      final cmd = CommandService.buildP2lClearStripsCommand(
        unitId: '0472',
        newProtocol: false,
        isNewGen: false,
      );
      expect((jsonDecode(cmd.payload) as Map)['cmds'], [
        {'cmd': 'clr_strips'},
      ]);
    });

    test('nová generace se starým FW jde na svůj P2L CMD topic', () {
      // FW < P2L_26071501NT nezná povel v topicu, ale topic jednotky zůstává
      // nový — jinak by příkaz šel na neexistující SERVER topic.
      final cmd = CommandService.buildP2lSetLedsCommand(
        unitId: '1209',
        ports: [0],
        x1: 0,
        x2: 9,
        styleId: 0,
        colorId: 0,
        newProtocol: false,
        isNewGen: true,
      );
      expect(cmd.topic, 'I/001209/P2L/011209/CMD');
    });
  });
}
