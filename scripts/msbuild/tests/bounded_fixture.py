import ctypes
import os
import subprocess
import sys
import time


if sys.argv[1] == "exit":
    print("owned fixture", os.getpid(), flush=True)
    sys.exit(int(sys.argv[2]))
if sys.argv[1] == "parent":
    executable = ctypes.create_unicode_buffer(32768)
    if not ctypes.windll.kernel32.GetModuleFileNameW(None, executable, len(executable)):
        raise ctypes.WinError()
    print("parent_pid=" + str(os.getpid()), flush=True)
    print("native_python=" + executable.value, flush=True)
    child = subprocess.Popen([executable.value, __file__, "child"])
    print("child_pid=" + str(child.pid), flush=True)
    time.sleep(60)
elif sys.argv[1] == "child":
    time.sleep(60)
else:
    raise ValueError("Unknown fixture mode")
