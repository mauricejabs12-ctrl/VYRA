"""Lokale Journal-Demo. Start: python main.py. Keine externen Pakete."""
from datetime import date
from pathlib import Path
import tkinter as tk
from tkinter import ttk, filedialog, messagebox
from ledger import Ledger, cents


def main():
    window = tk.Tk()
    window.title('VYRA Buchhaltungs-Starter')
    window.geometry('1000x680')
    ledger = Ledger(Path(__file__).with_name('journal.sqlite3'))
    frame = ttk.Frame(window, padding=20)
    frame.pack(fill='both', expand=True)
    ttk.Label(frame, text='Dein Journal', font=('Segoe UI', 24, 'bold')).pack(anchor='w')
    ttk.Label(frame, text='Entwicklungsbeispiel · EUR · ein lokales Journal · Storno statt Ueberschreiben').pack(anchor='w', pady=(0, 16))
    form = ttk.Frame(frame)
    form.pack(fill='x')
    fields = {}
    for i, (name, default) in enumerate((('Datum', date.today().isoformat()), ('Beleg', ''),
            ('Beschreibung', ''), ('Sollkonto', '1200'), ('Habenkonto', '8400'), ('Betrag EUR', ''))):
        ttk.Label(form, text=name).grid(row=i, column=0, sticky='w', padx=(0, 16), pady=3)
        variable = tk.StringVar(value=default)
        fields[name] = variable
        ttk.Entry(form, textvariable=variable, width=60).grid(row=i, column=1, sticky='ew', pady=3)
    form.columnconfigure(1, weight=1)
    columns = ('Datum', 'Beleg', 'Beschreibung', 'Konto', 'Soll EUR', 'Haben EUR')
    tree = ttk.Treeview(frame, columns=columns, show='headings', height=12, selectmode='browse')
    for name in columns:
        tree.heading(name, text=name)
        tree.column(name, width=130)
    identities = {}

    def refresh():
        tree.delete(*tree.get_children())
        identities.clear()
        for row in ledger.journal():
            values = (row['booking_date'], row['reference'], row['description'], row['account'],
                      f"{row['debit'] // 100}.{row['debit'] % 100:02d}",
                      f"{row['credit'] // 100}.{row['credit'] % 100:02d}")
            identities[tree.insert('', 'end', values=values)] = row['id']

    def action(callback):
        try:
            callback()
            refresh()
        except Exception as exc:
            messagebox.showerror('VYRA Journal', str(exc), parent=window)

    def post():
        value = cents(fields['Betrag EUR'].get().replace(',', '.'))
        if value <= 0:
            raise ValueError('Betrag muss positiv sein.')
        ledger.post(fields['Datum'].get(), fields['Beleg'].get(), fields['Beschreibung'].get(),
                    [(fields['Sollkonto'].get(), value, 0), (fields['Habenkonto'].get(), 0, value)])
        fields['Betrag EUR'].set('')

    def reverse():
        selected = tree.selection()
        if not selected:
            raise ValueError('Bitte eine Journalzeile auswaehlen.')
        if messagebox.askyesno('Storno', 'Die gesamte ausgewaehlte Buchung stornieren?', parent=window):
            ledger.reverse(identities[selected[0]], date.today().isoformat(), 'Storno-' + fields['Beleg'].get())

    def save(export):
        path = filedialog.asksaveasfilename(parent=window, defaultextension='.csv' if export else '.sqlite3',
                filetypes=[('CSV', '*.csv')] if export else [('SQLite', '*.sqlite3')])
        if path:
            (ledger.export_csv if export else ledger.backup)(path)

    buttons = ttk.Frame(frame)
    buttons.pack(fill='x', pady=14)
    for label, callback in (('Buchen', post), ('Stornieren', reverse),
                            ('CSV exportieren', lambda: save(True)), ('Backup', lambda: save(False))):
        ttk.Button(buttons, text=label, command=lambda fn=callback: action(fn)).pack(side='left', padx=(0, 8))
    tree.pack(fill='both', expand=True)
    ttk.Label(frame, text='Vor echtem Einsatz: Rollen, Mandanten, Belegarchiv, Steuerlogik, Periodenabschluss und Konformitaet ergaenzen.').pack(anchor='w', pady=(12, 0))
    window.protocol('WM_DELETE_WINDOW', lambda: (ledger.close(), window.destroy()))
    refresh()
    window.mainloop()


if __name__ == '__main__':
    main()
