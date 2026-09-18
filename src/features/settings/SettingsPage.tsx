import { useState, type FormEvent } from 'react'
import { useQuery, useQueryClient } from '@tanstack/react-query'
import { Card, ChoiceGroup, ErrorMessage, Loading, Notice, PageHeader, TextArea, TextInput } from '../../components/ui'
import { readRpc } from '../../lib/rpc'
import { useCommand } from '../../lib/useCommand'

type ShopSettings = {
  name: string
  address: string
  phone: string
  receipt_width: 58 | 80
  configured: boolean
  version: number
}

type Form = { name: string; address: string; phone: string; receiptWidth: '58' | '80' }

const PHONE_PATTERN = /^[\d\s+\-.()]*$/

/** Masalah isian pengaturan (null bila siap). Batas sama dengan server. */
export function settingsError(form: Form): string | null {
  const name = form.name.trim()
  if (name.length < 1 || name.length > 100) return 'Nama toko wajib diisi (maksimal 100 huruf).'
  if (form.address.trim().length > 300) return 'Alamat maksimal 300 huruf.'
  if (form.phone.trim().length > 40 || !PHONE_PATTERN.test(form.phone.trim())) return 'Telepon hanya angka, spasi, dan tanda + - . ( ).'
  return null
}

function SettingsForm({ settings }: { settings: ShopSettings }) {
  const queryClient = useQueryClient()
  const [form, setForm] = useState<Form>({
    name: settings.name ?? '', address: settings.address ?? '', phone: settings.phone ?? '',
    receiptWidth: settings.receipt_width === 80 ? '80' : '58',
  })
  const [touched, setTouched] = useState(false)
  const [saved, setSaved] = useState(false)
  const command = useCommand<{ version: number }, Record<string, unknown>>('update_shop_settings_v1')
  const error = settingsError(form)
  const set = (patch: Partial<Form>) => { setForm(f => ({ ...f, ...patch })); setSaved(false); command.reset() }

  async function submit(event: FormEvent) {
    event.preventDefault()
    setTouched(true)
    if (error) return
    const result = await command.run({
      expected_version: settings.version, name: form.name.trim(), address: form.address.trim(),
      phone: form.phone.trim(), receipt_width: Number(form.receiptWidth),
    })
    if (result) {
      setSaved(true)
      await queryClient.invalidateQueries()
    }
  }

  return (
    <form onSubmit={submit} noValidate>
      <TextInput label="Nama toko" value={form.name} onChange={name => set({ name })} required maxLength={100} />
      <TextArea label="Alamat" value={form.address} onChange={address => set({ address })} rows={2} maxLength={300} />
      <TextInput type="tel" label="Telepon" value={form.phone} onChange={phone => set({ phone })} maxLength={40} />
      <ChoiceGroup label="Lebar kertas struk" value={form.receiptWidth} onChange={receiptWidth => set({ receiptWidth })} options={[
        { value: '58', label: '58 mm', description: 'Printer struk kecil' },
        { value: '80', label: '80 mm', description: 'Printer struk lebar' },
      ]} />
      <p className="muted">Zona waktu toko tetap WIB (Asia/Jakarta) dan mata uang Rupiah.</p>
      {touched && error && <ErrorMessage error={error} />}
      <ErrorMessage error={command.error} />
      {saved && <Notice tone="success">Pengaturan tersimpan. Struk berikutnya memakai data ini.</Notice>}
      <button type="submit" className="ui-button ui-button-primary" disabled={command.busy}>
        {command.busy ? 'Menyimpan…' : 'Simpan pengaturan'}
      </button>
    </form>
  )
}

/** Identitas toko untuk struk (FR-SET-01). Hanya pemilik. */
export function SettingsPage() {
  const settings = useQuery({ queryKey: ['settings', 'shop'], queryFn: () => readRpc<ShopSettings>('get_shop_settings_v1') })
  return (
    <section>
      <PageHeader title="Pengaturan toko" description="Nama, alamat, dan telepon dicetak di struk." />
      {settings.isPending && <Loading label="Memuat pengaturan…" />}
      <ErrorMessage error={settings.error} />
      {settings.data && (
        <Card>
          {!settings.data.configured && <Notice tone="warning">Identitas toko belum lengkap. Isi nama toko sebelum mencetak struk.</Notice>}
          <SettingsForm key={settings.data.version} settings={settings.data} />
        </Card>
      )}
    </section>
  )
}
