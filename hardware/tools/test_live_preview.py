import base64
import importlib.util
import json
import struct
import unittest
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


if __name__ == "__main__":
    unittest.main()
