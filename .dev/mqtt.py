#!/usr/bin/env python3
"""P2L Tester — MQTT helper pro lokální ladění proti brokeru.

Znovupoužitelný nástroj (paho-mqtt 2.x) pro subscribe / publish / trace
provozu P2L jednotek. Použitelný i ručně, bez Clauda.

Příklady:
    # poslouchat discovery jedné/všech jednotek
    python .dev/mqtt.py sub "D/+/UNIT/+/ALIVE" --host 185.149.129.164

    # trace standardních P2L topiců na 30 s
    python .dev/mqtt.py trace --host localhost --seconds 30

    # publish příkazu (POZOR: reálný příkaz na HW!)
    python .dev/mqtt.py pub "I/001209/UNIT/001209/GET-DEVICES" "{}" --host localhost

    # broker přes WebSocket
    python .dev/mqtt.py trace --host localhost --port 9001 --ws --path /mqtt

Připojení lze zadat i přes env proměnné:
    P2L_MQTT_HOST, P2L_MQTT_PORT, P2L_MQTT_USER, P2L_MQTT_PASS
"""
import argparse
import os
import sys
import time

# Windows konzole často jede v cp1252 → vynutit UTF-8, ať nepadá na diakritice.
try:
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")
except Exception:
    pass

try:
    import paho.mqtt.client as mqtt
    from paho.mqtt.enums import CallbackAPIVersion
except ImportError:
    sys.exit("Chybí paho-mqtt. Nainstaluj: pip install paho-mqtt")


# Standardní P2L topicy (viz CLAUDE.md / MQTT-TOPICS.md) pro `trace`.
DEFAULT_TRACE_TOPICS = [
    "D/+/UNIT/+/ALIVE",             # discovery + battery/firmware
    "D/+/+/+/ALIVE",                # device ALIVE (DIST/DISP/BTN/LEDS)
    "D/+/DIST/+/UPDATE",            # živá vzdálenost DIST
    "A/SERVER/+/CMD",               # odpověď na get_param
    "O/+/UNIT/+/#",                 # potvrzení device operací (GET/ADD/REPLACE/SET-ID/SCAN)
    "L/#",                          # logy
]


def _ts():
    return time.strftime("%H:%M:%S", time.localtime())


def _build_client(args):
    cid = args.client_id or f"p2l-helper-{os.getpid()}"
    transport = "websockets" if args.ws else "tcp"
    client = mqtt.Client(
        CallbackAPIVersion.VERSION2,
        client_id=cid,
        transport=transport,
        clean_session=True,
    )
    if args.ws:
        client.ws_set_options(path=args.path)
    if args.tls:
        client.tls_set()
    if args.user:
        client.username_pw_set(args.user, args.password or "")
    return client


def _connect(client, args, on_connect_topics=None):
    connected = {"ok": False, "rc": None}

    def on_connect(c, userdata, flags, reason_code, properties):
        connected["rc"] = reason_code
        if reason_code == 0 or getattr(reason_code, "is_failure", False) is False:
            connected["ok"] = True
            print(f"[{_ts()}] PŘIPOJENO k {args.host}:{args.port} "
                  f"({'ws' if args.ws else 'tcp'}{'+tls' if args.tls else ''})")
            if on_connect_topics:
                for t in on_connect_topics:
                    c.subscribe(t, qos=args.qos)
                    print(f"[{_ts()}] SUB  {t}")
        else:
            print(f"[{_ts()}] PŘIPOJENÍ ODMÍTNUTO: {reason_code}")

    client.on_connect = on_connect
    print(f"[{_ts()}] připojuji se k {args.host}:{args.port} …")
    client.connect(args.host, args.port, keepalive=args.keepalive)
    return connected


def _decode(payload: bytes):
    try:
        return payload.decode("utf-8")
    except UnicodeDecodeError:
        return payload.hex(" ")  # BIN payload → hex dump


def cmd_sub(args, topics):
    client = _build_client(args)
    count = {"n": 0}

    def on_message(c, userdata, msg):
        count["n"] += 1
        print(f"[{_ts()}] {msg.topic}  ->  {_decode(msg.payload)}")

    client.on_message = on_message
    _connect(client, args, on_connect_topics=topics)
    client.loop_start()
    _run_for(args.seconds)
    client.loop_stop()
    client.disconnect()
    print(f"[{_ts()}] hotovo — přijato {count['n']} zpráv.")


def cmd_pub(args):
    client = _build_client(args)
    _connect(client, args)
    client.loop_start()
    # počkat na spojení (max 5 s)
    for _ in range(50):
        if client.is_connected():
            break
        time.sleep(0.1)
    if not client.is_connected():
        client.loop_stop()
        sys.exit(f"[{_ts()}] CHYBA: nepodařilo se připojit k {args.host}:{args.port}")
    info = client.publish(args.topic, args.payload, qos=args.qos, retain=args.retain)
    info.wait_for_publish(timeout=5)
    print(f"[{_ts()}] PUB  {args.topic}  ->  {args.payload}")
    client.loop_stop()
    client.disconnect()


def _run_for(seconds):
    """Běž N sekund; seconds<=0 → do Ctrl+C."""
    try:
        if seconds and seconds > 0:
            time.sleep(seconds)
        else:
            print(f"[{_ts()}] poslouchám … (Ctrl+C pro ukončení)")
            while True:
                time.sleep(0.5)
    except KeyboardInterrupt:
        print(f"\n[{_ts()}] přerušeno uživatelem.")


def build_parser():
    # Connection flagy jako sdílený rodič → fungují i ZA subcommandem
    # (python mqtt.py sub "topic" --host X).
    conn = argparse.ArgumentParser(add_help=False)
    conn.add_argument("--host", default=os.environ.get("P2L_MQTT_HOST", "localhost"))
    conn.add_argument("--port", type=int, default=int(os.environ.get("P2L_MQTT_PORT", "1883")))
    conn.add_argument("--user", default=os.environ.get("P2L_MQTT_USER"))
    conn.add_argument("--password", "--pass", dest="password",
                      default=os.environ.get("P2L_MQTT_PASS"))
    conn.add_argument("--ws", action="store_true", help="připojit přes WebSocket")
    conn.add_argument("--path", default="/mqtt", help="WS cesta (default /mqtt)")
    conn.add_argument("--tls", action="store_true", help="TLS (mqtts/wss)")
    conn.add_argument("--qos", type=int, default=0, choices=[0, 1, 2])
    conn.add_argument("--keepalive", type=int, default=30)
    conn.add_argument("--client-id", default=None)

    p = argparse.ArgumentParser(description="P2L MQTT helper", parents=[conn])
    sub = p.add_subparsers(dest="command", required=True)

    s_sub = sub.add_parser("sub", parents=[conn], help="subscribe na topic(y)")
    s_sub.add_argument("topics", nargs="+", help="jeden a více topiců (podpora +/#)")
    s_sub.add_argument("--seconds", type=int, default=0, help="0 = do Ctrl+C")

    s_trace = sub.add_parser("trace", parents=[conn], help="subscribe na standardní P2L topicy")
    s_trace.add_argument("--seconds", type=int, default=0, help="0 = do Ctrl+C")

    s_pub = sub.add_parser("pub", parents=[conn], help="publish příkazu (POZOR: reálný HW!)")
    s_pub.add_argument("topic")
    s_pub.add_argument("payload")
    s_pub.add_argument("--retain", action="store_true")

    return p


def main():
    args = build_parser().parse_args()
    if args.command == "sub":
        cmd_sub(args, args.topics)
    elif args.command == "trace":
        cmd_sub(args, DEFAULT_TRACE_TOPICS)
    elif args.command == "pub":
        cmd_pub(args)


if __name__ == "__main__":
    main()
