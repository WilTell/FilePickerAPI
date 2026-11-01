"""Управление чужой консолью и скрытым окном из msi-probe.ps1.

Раннер не даёт интерактивного ввода, поэтому нажатия, Ctrl+C и закрытие
окна консоли делаются через Win32 API.

    tool.py type <pid> <текст>      ввести строку с Enter в консоль процесса
    tool.py ctrl-c <pid>            Ctrl+C всем в консоли процесса
    tool.py close-console <pid>     WM_CLOSE окну консоли процесса
    tool.py dump <pid>              вывести содержимое экрана консоли
    tool.py window-close            WM_CLOSE скрытому окну
    tool.py window-crash            попросить скрытое окно упасть
"""

import ctypes
import ctypes.wintypes as w
import sys
import time

import win32con
import win32gui

WINDOW_CLASS = "FilePickerProbe.Instance"
WM_APP_CRASH = win32con.WM_APP + 1
KEY_EVENT = 1
VK_RETURN = 0x0D
GENERIC_RW = 0xC0000000
FILE_SHARE_RW = 3
OPEN_EXISTING = 3

kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
kernel32.CreateFileW.restype = w.HANDLE
kernel32.GetConsoleWindow.restype = w.HWND


class KeyEvent(ctypes.Structure):
    """KEY_EVENT_RECORD."""

    _fields_ = (
        ("down", w.BOOL),
        ("repeat", w.WORD),
        ("vk", w.WORD),
        ("scan", w.WORD),
        ("char", w.WCHAR),
        ("control", w.DWORD),
    )


class InputRecord(ctypes.Structure):
    """INPUT_RECORD только с событием клавиши."""

    _fields_ = (("event_type", w.WORD), ("key", KeyEvent))


class BufferInfo(ctypes.Structure):
    """CONSOLE_SCREEN_BUFFER_INFO."""

    _fields_ = (
        ("size", w._COORD),
        ("cursor", w._COORD),
        ("attributes", w.WORD),
        ("window", w.SMALL_RECT),
        ("maximum", w._COORD),
    )


def attach(pid: int) -> None:
    """Подключиться к консоли процесса."""
    kernel32.FreeConsole()
    if not kernel32.AttachConsole(pid):
        raise ctypes.WinError(ctypes.get_last_error())


def console_file(name: str) -> int:
    """Открыть CONIN$ или CONOUT$."""
    return kernel32.CreateFileW(
        name, GENERIC_RW, FILE_SHARE_RW, None, OPEN_EXISTING, 0, None
    )


def type_text(pid: int, text: str) -> None:
    """Ввести строку с Enter."""
    attach(pid)
    handle = console_file("CONIN$")
    records = []
    for char in text + "\r":
        vk = VK_RETURN if char == "\r" else 0
        for down in (True, False):
            key = KeyEvent(down, 1, vk, 0, char, 0)
            records.append(InputRecord(KEY_EVENT, key))
    array = (InputRecord * len(records))(*records)
    written = w.DWORD()
    if not kernel32.WriteConsoleInputW(
        handle, array, len(records), ctypes.byref(written)
    ):
        raise ctypes.WinError(ctypes.get_last_error())


def ctrl_c(pid: int) -> None:
    """Послать Ctrl+C всем в консоли, кроме себя."""
    attach(pid)
    kernel32.SetConsoleCtrlHandler(None, True)
    kernel32.GenerateConsoleCtrlEvent(0, 0)
    time.sleep(1)


def close_console(pid: int) -> None:
    """Закрыть окно консоли, как крестиком."""
    attach(pid)
    hwnd = kernel32.GetConsoleWindow()
    print(f"console window {hwnd}", flush=True)
    # Сам инструмент тоже в этой консоли: он не должен закрыться раньше
    kernel32.SetConsoleCtrlHandler(None, True)
    win32gui.PostMessage(hwnd, win32con.WM_SYSCOMMAND, win32con.SC_CLOSE, 0)
    time.sleep(3)
    print(f"window alive {win32gui.IsWindow(hwnd)}", flush=True)


def dump(pid: int) -> str:
    """Вернуть текст экрана консоли."""
    attach(pid)
    handle = console_file("CONOUT$")
    info = BufferInfo()
    kernel32.GetConsoleScreenBufferInfo(handle, ctypes.byref(info))
    width = info.size.X
    lines = []
    for y in range(info.cursor.Y + 1):
        buffer = ctypes.create_unicode_buffer(width + 1)
        count = w.DWORD()
        kernel32.ReadConsoleOutputCharacterW(
            handle, buffer, width, w._COORD(0, y), ctypes.byref(count)
        )
        lines.append(buffer.value.rstrip())
    return "\n".join(lines)


def post_to_window(message: int) -> None:
    """Послать сообщение скрытому окну."""
    hwnd = win32gui.FindWindow(WINDOW_CLASS, None)
    if not hwnd:
        sys.exit("window not found")
    win32gui.PostMessage(hwnd, message, 0, 0)


def main() -> None:
    """Разобрать команду."""
    command, *rest = sys.argv[1:]
    if command == "type":
        type_text(int(rest[0]), rest[1])
    elif command == "ctrl-c":
        ctrl_c(int(rest[0]))
    elif command == "close-console":
        close_console(int(rest[0]))
    elif command == "dump":
        text = dump(int(rest[0]))
        kernel32.FreeConsole()
        sys.stdout.buffer.write(text.encode("utf-8"))
    elif command == "window-close":
        post_to_window(win32con.WM_CLOSE)
    elif command == "window-crash":
        post_to_window(WM_APP_CRASH)
    else:
        sys.exit(f"unknown command {command}")


if __name__ == "__main__":
    main()
