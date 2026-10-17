import base64
import asyncio
import importlib.util
import json
import struct
import unittest
import types
from unittest.mock import AsyncMock, MagicMock, patch
from pathlib import Path

spec = importlib.util.spec_from_file_location("live_preview", Path(__file__).with_name("live_preview.py"))
preview = importlib.util.module_from_spec(spec)
spec.loader.exec_module(preview)


class PreviewTests(unittest.TestCase):
    def test_fragmented_and_concatenated_messages(self):
        source = [{"kind": "look", "id": "a", "task": "计算"}, {"kind": "decision", "id": "a"}]
        wire = b"".join(struct.pack(">I", len(b)) + b for b in
                        (json.dumps(e, ensure_ascii=False).encode() for e in source))
        events = []
        decoder = preview.Decoder(events.append)
        for i in range(0, len(wire), 3):
            decoder.feed(wire[i:i+3])
        self.assertEqual(events, source)

    def test_rejects_unbounded_length_and_clears_buffer(self):
        decoder = preview.Decoder(lambda _: self.fail("must not emit"))
        with self.assertRaises(ValueError):
            decoder.feed(struct.pack(">I", preview.MAX_EVENT + 1))
        self.assertFalse(decoder.buffer)

    def test_exact_image_bytes_and_no_base64_in_state(self):
        state = preview.Events()
        image = b"\xff\xd8\xff\xd9"
        state.add({"kind": "look", "id": "same-frame", "image": base64.b64encode(image).decode()})
        state.add({"kind": "decision", "id": "same-frame", "actions": ["tap 500 800"]})
        self.assertEqual(state.frames["same-frame"], image)
        self.assertNotIn("image", state.snapshot()["events"][0])
        self.assertEqual(state.snapshot()["events"][1]["id"], "same-frame")

    def test_incomplete_frame_never_published(self):
        events = []
        decoder = preview.Decoder(events.append)
        decoder.feed(struct.pack(">I", 100) + b'{"kind": "look"')
        self.assertFalse(events)

    def test_invalid_image_is_not_shown_as_current_frame(self):
        state = preview.Events()
        with self.assertRaises(ValueError):
            state.add({"kind": "look", "id": "a", "image": base64.b64encode(b"not JPEG").decode()})
        self.assertFalse(state.frames)
        self.assertFalse(state.events)

    def test_bounded_retention(self):
        state = preview.Events()
        for i in range(150):
            state.add({"kind": "look", "id": str(i), "image": base64.b64encode(b"\xff\xd8").decode()})
        self.assertEqual(len(state.events), 120)
        self.assertEqual(len(state.frames), 120)
        self.assertNotIn("0", state.frames)


class ConnectionTests(unittest.IsolatedAsyncioTestCase):
    async def test_name_only_advertisement_fallback_preserves_service_filter_first(self):
        phone = object()
        find = AsyncMock(side_effect=[None, phone])
        bleak = types.SimpleNamespace(BleakScanner=types.SimpleNamespace(find_device_by_filter=find))
        with patch.dict("sys.modules", {"bleak": bleak}):
            self.assertIs(await preview.find_preview_phone(), phone)
        self.assertEqual(find.await_args_list[0].kwargs["service_uuids"], [preview.SERVICE])
        self.assertNotIn("service_uuids", find.await_args_list[1].kwargs)
        predicate = find.await_args_list[1].args[0]
        self.assertTrue(predicate(None, types.SimpleNamespace(local_name="Tianbao Preview", service_uuids=[])))
        self.assertFalse(predicate(None, types.SimpleNamespace(local_name="Other phone", service_uuids=[])))

    async def test_missing_service_never_receives_session_token(self):
        client = MagicMock()
        client.services.get_service.return_value = None
        client.start_notify = AsyncMock()
        client.write_gatt_char = AsyncMock()
        context = MagicMock()
        context.__aenter__ = AsyncMock(return_value=client)
        context.__aexit__ = AsyncMock(return_value=False)
        bleak = types.SimpleNamespace(BleakClient=MagicMock(return_value=context),
            BleakScanner=types.SimpleNamespace(find_device_by_filter=AsyncMock(return_value=object())))
        state = preview.Events()
        with patch.dict("sys.modules", {"bleak": bleak}), \
             patch.object(preview, "preview_control", AsyncMock()), \
             patch.object(preview.asyncio, "sleep", AsyncMock(side_effect=asyncio.CancelledError)):
            with self.assertRaises(asyncio.CancelledError):
                await preview.watch(state, "a" * 32)
        self.assertIn("核对截图服务", state.snapshot()["status"])
        client.start_notify.assert_not_awaited()
        client.write_gatt_char.assert_not_awaited()

    async def test_phone_confirmation_reaches_viewer_without_model_or_hid(self):
        client = MagicMock()
        transport = {}
        async def notify(_, callback):
            transport["receive"] = callback
        async def authorize(_, value, **kwargs):
            self.assertEqual(value, b"\xaa" * 16)
            payload = json.dumps({"kind": "state", "state": "ready"}).encode()
            transport["receive"](None, struct.pack(">I", len(payload)) + payload)
            transport["disconnect"](None)
        client.start_notify = AsyncMock(side_effect=notify)
        client.write_gatt_char = AsyncMock(side_effect=authorize)
        def connect(*args, **kwargs):
            transport["disconnect"] = kwargs["disconnected_callback"]
            context = MagicMock()
            context.__aenter__ = AsyncMock(return_value=client)
            context.__aexit__ = AsyncMock(return_value=False)
            return context
        bleak = types.SimpleNamespace(BleakClient=connect,
            BleakScanner=types.SimpleNamespace(find_device_by_filter=AsyncMock(return_value=object())))
        state = preview.Events()
        with patch.dict("sys.modules", {"bleak": bleak}), \
             patch.object(preview, "preview_control", AsyncMock()), \
             patch.object(preview.asyncio, "sleep", AsyncMock(side_effect=asyncio.CancelledError)):
            with self.assertRaises(asyncio.CancelledError):
                await preview.watch(state, "a" * 32)
        self.assertIn("已连接", state.snapshot()["status"])
        self.assertEqual(state.snapshot()["events"][0]["state"], "ready")
        self.assertFalse(state.frames)
        self.assertEqual(client.write_gatt_char.await_count, 1)
        self.assertEqual(client.write_gatt_char.await_args.args[0], preview.AUTH)

    async def test_failure_status_identifies_subscription_or_authorization_stage(self):
        for operation, expected in (("start_notify", "订阅截图通知"),
                                    ("write_gatt_char", "验证会话授权")):
            with self.subTest(operation=operation):
                client = MagicMock()
                client.start_notify = AsyncMock()
                client.write_gatt_char = AsyncMock()
                getattr(client, operation).side_effect = RuntimeError("diagnostic failure")
                context = MagicMock()
                context.__aenter__ = AsyncMock(return_value=client)
                context.__aexit__ = AsyncMock(return_value=False)
                bleak = types.SimpleNamespace(
                    BleakClient=MagicMock(return_value=context),
                    BleakScanner=types.SimpleNamespace(find_device_by_filter=AsyncMock(return_value=object())))
                state = preview.Events()
                with patch.dict("sys.modules", {"bleak": bleak}), \
                     patch.object(preview, "preview_control", AsyncMock()), \
                     patch.object(preview.asyncio, "sleep", AsyncMock(side_effect=asyncio.CancelledError)):
                    with self.assertRaises(asyncio.CancelledError):
                        await preview.watch(state, "a" * 32)
                self.assertIn(expected, state.snapshot()["status"])

    async def test_phone_discovery_uses_explicit_service_filter(self):
        find = AsyncMock(side_effect=asyncio.CancelledError)
        bleak = types.SimpleNamespace(BleakClient=MagicMock(),
                                      BleakScanner=types.SimpleNamespace(find_device_by_filter=find))
        control = AsyncMock()
        with patch.dict("sys.modules", {"bleak": bleak}), patch.object(preview, "preview_control", control):
            with self.assertRaises(asyncio.CancelledError):
                await preview.watch(preview.Events(), "a" * 32, "/dev/test-board")
        control.assert_awaited_once_with("a" * 32, "/dev/test-board")
        self.assertEqual(find.await_args.kwargs["service_uuids"], [preview.SERVICE])

    async def test_usb_authorization_sends_only_preview_control(self):
        link = MagicMock()
        link.readline.return_value = b"990801 ok\n"
        serial = types.SimpleNamespace(Serial=MagicMock())
        serial.Serial.return_value.__enter__.return_value = link
        with patch.dict("sys.modules", {"serial": serial}), patch.object(preview.Path, "exists", return_value=True):
            await preview.preview_control("a" * 32, "/dev/test-board")
        link.write.assert_called_once_with(b"990801 app preview " + b"a" * 32 + b"\n")


if __name__ == "__main__":
    unittest.main()
