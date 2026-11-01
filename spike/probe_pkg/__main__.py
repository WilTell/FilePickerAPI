"""Пробный exe для изменения user-logon-autostart (задачи 1.5 и 1.6).

Повторяет только то, на чём держится план: режим консоли attach,
скрытое окно, консольный обработчик, RegisterApplicationRestart и
событие остановки. Каждый шаг пишется в общий журнал JSONL, по которому
msi-probe.ps1 определяет, что произошло.
"""

import ctypes
import json
import os
import sys
import threading
import time
from pathlib import Path

import win32api
import win32con
import win32evtlog
import win32gui
from win32com.shell import shell

LOG = Path(r"C:\ProgramData\FilePickerProbe\probe.jsonl")
SOURCE = "FilePickerProbe"
WINDOW_CLASS = "FilePickerProbe.Instance"
EVENT_STOPPED = 1001
WM_APP_CRASH = win32con.WM_APP + 1
RESTART_FLAGS = 1 | 2 | 8  # NO_CRASH, NO_HANG, NO_REBOOT

stop = threading.Event()


def identity() -> dict[str, object]:
    """Вернуть, кто и где работает."""
    session = ctypes.c_ulong()
    ctypes.windll.kernel32.ProcessIdToSessionId(os.getpid(), ctypes.byref(session))
    return {
        "pid": os.getpid(),
        "user": win32api.GetUserNameEx(win32con.NameSamCompatible),
        "session": session.value,
    }


def log(kind: str, **fields: object) -> None:
    """Дописать запись в общий журнал."""
    record = {"t": time.time(), "kind": kind, **identity(), **fields}
    with LOG.open("a", encoding="utf-8") as stream:
        stream.write(json.dumps(record, ensure_ascii=False) + "\n")


def report_stop(reason: str) -> None:
    """Записать событие остановки с кириллицей."""
    handle = win32evtlog.RegisterEventSource(None, SOURCE)
    try:
        win32evtlog.ReportEvent(
            handle,
            win32evtlog.EVENTLOG_INFORMATION_TYPE,
            0,
            EVENT_STOPPED,
            None,
            [f"Пробный exe остановлен: {reason}, ёЁ"],
            None,
        )
    finally:
        win32evtlog.DeregisterEventSource(handle)


def console_handler(ctrl_type: int) -> bool:
    """Обработать Ctrl+C и закрытие окна консоли."""
    log("console_ctrl", ctrl_type=ctrl_type)
    if ctrl_type == win32con.CTRL_CLOSE_EVENT:
        # Секунда — чтобы проверить, что Windows даёт время на финализацию
        time.sleep(1)
        report_stop("закрытие консоли")
        log("close_done")
        os._exit(0)
    stop.set()
    return True


def wndproc(hwnd: int, message: int, wparam: int, lparam: int) -> int:
    """Обработать сообщения завершения сеанса и закрытия."""
    if message == win32con.WM_QUERYENDSESSION:
        log("query_end_session", wparam=wparam, lparam=lparam)
        return 1
    if message == win32con.WM_ENDSESSION:
        log("end_session", wparam=wparam, lparam=lparam)
        if wparam:
            report_stop(f"завершение сеанса lParam={lparam:#x}")
            log("end_session_done")
            os._exit(0)
        return 0
    if message == win32con.WM_CLOSE:
        log("wm_close")
        stop.set()
        return 0
    if message == WM_APP_CRASH:
        log("crash_requested")
        # ctypes перехватил бы нарушение доступа и превратил в OSError
        ctypes.windll.kernel32.RaiseFailFastException(None, None, 0)
    return win32gui.DefWindowProc(hwnd, message, wparam, lparam)


def run_window() -> None:
    """Создать скрытое окно верхнего уровня и крутить его сообщения."""
    window_class = win32gui.WNDCLASS()
    window_class.lpszClassName = WINDOW_CLASS
    window_class.lpfnWndProc = wndproc
    atom = win32gui.RegisterClass(window_class)
    hwnd = win32gui.CreateWindowEx(
        0, atom, WINDOW_CLASS, win32con.WS_OVERLAPPED, 0, 0, 0, 0, 0, 0, 0, None
    )
    log("window_created", hwnd=hwnd, visible=bool(win32gui.IsWindowVisible(hwnd)))
    win32gui.PumpMessages()


def file_version(path: str) -> str:
    """Вернуть версию файла из VS_FIXEDFILEINFO."""
    info = win32api.GetFileVersionInfo(path, "\\")
    high, low = info["FileVersionMS"], info["FileVersionLS"]
    return f"{high >> 16}.{high & 0xFFFF}.{low >> 16}.{low & 0xFFFF}"


def main() -> int:
    """Работать до команды остановки."""
    exe = win32api.GetModuleFileName(None)
    kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
    # --no-flags — контрольный запуск: показывает, что проверка сбоя вообще
    # способна заметить перезапуск
    flags = 0 if "--no-flags" in sys.argv else RESTART_FLAGS
    restart_result = kernel32.RegisterApplicationRestart(None, flags)
    print("probe console line stdout", flush=True)
    print("probe console line stderr", file=sys.stderr, flush=True)
    log(
        "start",
        argv=sys.argv[1:],
        exe=exe,
        version=file_version(exe),
        console_window=kernel32.GetConsoleWindow() != 0,
        stdout=str(sys.stdout),
        local_appdata=shell.SHGetKnownFolderPath(shell.FOLDERID_LocalAppData, 0, 0),
        restart_result=restart_result,
    )
    win32api.SetConsoleCtrlHandler(console_handler, True)
    threading.Thread(target=run_window, daemon=True).start()
    stop.wait()
    report_stop("обычная остановка")
    log("stopped")
    os._exit(0)


if __name__ == "__main__":
    sys.exit(main())
