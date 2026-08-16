import tkinter as tk
from tkinter import ttk, simpledialog, messagebox
import win32api
from hotkey_manager import validate_hotkey_string


class PreferencesWindow:
    def __init__(self, settings, on_save):
        self._settings = settings
        self._on_save = on_save
        self._root = tk.Tk()
        self._root.title("Centered Preferences")
        self._root.resizable(False, False)
        self._build()
        self._root.mainloop()

    def _build(self):
        r = self._root
        pad = {"padx": 10, "pady": 4}

        def row(label, widget, i):
            tk.Label(r, text=label, anchor="e", width=22).grid(row=i, column=0, **pad)
            widget.grid(row=i, column=1, sticky="w", **pad)

        self._auto = tk.BooleanVar(value=self._settings.auto_center_enabled)
        row("Auto-Center:", ttk.Checkbutton(r, variable=self._auto), 0)

        self._active_hk = tk.StringVar(value=self._settings.center_active_hotkey)
        row("Center Active Hotkey:", ttk.Entry(r, textvariable=self._active_hk, width=20), 1)

        self._all_hk = tk.StringVar(value=self._settings.center_all_hotkey)
        row("Center All Hotkey:", ttk.Entry(r, textvariable=self._all_hk, width=20), 2)

        self._anim = tk.StringVar(value=self._settings.animation_style)
        row(
            "Animation Style:",
            ttk.Combobox(
                r, textvariable=self._anim,
                values=["Instant", "Subtle", "Smooth"],
                state="readonly", width=12
            ),
            3
        )

        self._follow = tk.BooleanVar(value=self._settings.center_on_window_display)
        row("Follow Window Display:", ttk.Checkbutton(r, variable=self._follow), 4)

        display_names = []
        for hm, _, _ in win32api.EnumDisplayMonitors(None, None):
            display_names.append(win32api.GetMonitorInfo(hm)["Device"])
        self._display = tk.StringVar(
            value=self._settings.fixed_display_name
            or (display_names[0] if display_names else "")
        )
        row(
            "Fixed Display:",
            ttk.Combobox(
                r, textvariable=self._display,
                values=display_names, state="readonly", width=20
            ),
            5
        )

        self._login = tk.BooleanVar(value=self._settings.launch_at_login)
        row("Launch at Login:", ttk.Checkbutton(r, variable=self._login), 6)

        # Exclusions list
        tk.Label(r, text="Excluded Processes:", anchor="e", width=22).grid(row=7, column=0, **pad)
        frame = tk.Frame(r)
        frame.grid(row=7, column=1, sticky="w", **pad)
        self._excl_var = tk.StringVar(value=self._settings.excluded_process_names)
        self._lb = tk.Listbox(frame, listvariable=self._excl_var, height=4, width=22)
        self._lb.pack(side="left")
        btn_frame = tk.Frame(frame)
        btn_frame.pack(side="left", padx=4)
        ttk.Button(btn_frame, text="Add",    command=self._add_exclusion).pack(pady=2)
        ttk.Button(btn_frame, text="Remove", command=self._remove_exclusion).pack(pady=2)

        ttk.Button(r, text="Save", command=self._save).grid(
            row=8, column=1, sticky="e", **pad
        )

    def _add_exclusion(self):
        name = simpledialog.askstring(
            "Add Exclusion",
            "Enter process name to exclude (e.g. notepad):",
            parent=self._root
        )
        if name:
            self._lb.insert("end", name.strip())

    def _remove_exclusion(self):
        sel = self._lb.curselection()
        if sel:
            self._lb.delete(sel[0])

    def _save(self):
        s = self._settings
        active_hk = self._active_hk.get()
        all_hk = self._all_hk.get()
        
        # Validate hotkeys before saving
        if not validate_hotkey_string(active_hk):
            messagebox.showerror(
                "Invalid Hotkey",
                f"Active window hotkey '{active_hk}' is invalid.\n"
                "Must have at least one modifier (Ctrl/Alt/Shift/Win) and one key (A-Z).",
                parent=self._root
            )
            return
        
        if not validate_hotkey_string(all_hk):
            messagebox.showerror(
                "Invalid Hotkey",
                f"Center all hotkey '{all_hk}' is invalid.\n"
                "Must have at least one modifier (Ctrl/Alt/Shift/Win) and one key (A-Z).",
                parent=self._root
            )
            return
        
        s.auto_center_enabled      = self._auto.get()
        s.center_active_hotkey     = active_hk
        s.center_all_hotkey        = all_hk
        s.animation_style          = self._anim.get()
        s.center_on_window_display = self._follow.get()
        s.fixed_display_name       = self._display.get()
        s.excluded_process_names   = list(self._lb.get(0, "end"))
        if self._login.get() != s.launch_at_login:
            s.set_launch_at_login(self._login.get())
        s.save()
        self._on_save()
        self._root.destroy()
