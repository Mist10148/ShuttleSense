from types import SimpleNamespace

import numpy as np

from shuttlesense.pose.watch_split_detector import BOUNDARY, SplitDetectorSession


def test_split_detector_reuses_input_buffer_with_updated_values():
    class Binding:
        def __init__(self):
            self.inputs, self.outputs = {}, []
        def bind_cpu_input(self, name, value):
            self.inputs[name] = value
        def bind_ortvalue_input(self, name, value):
            self.inputs[name] = value
        def bind_output(self, name, device):
            self.outputs.append(name)
        def synchronize_inputs(self):
            pass
        def synchronize_outputs(self):
            pass
        def get_outputs(self):
            return [self.inputs["input"].copy() + i for i in range(len(BOUNDARY))]
        def copy_outputs_to_cpu(self):
            return [self.inputs[BOUNDARY[0]].copy() for _ in self.outputs]
    class Front:
        def io_binding(self):
            return Binding()
        def run_with_iobinding(self, binding):
            pass
    class Post:
        def io_binding(self):
            return Binding()
        def run_with_iobinding(self, binding):
            pass
    original = SimpleNamespace(get_inputs=lambda: [SimpleNamespace(name="input", shape=[1, 3])],
                               get_outputs=lambda: [SimpleNamespace(name="dets")])
    session = SplitDetectorSession(original, Front(), Post())
    assert session.run(None, {"input": np.array([[1, 2, 3]], dtype=np.float32)})[0].tolist() == [
        [1, 2, 3]
    ]
    assert session.run(None, {"input": np.array([[4, 5, 6]], dtype=np.float32)})[0].tolist() == [
        [4, 5, 6]
    ]
