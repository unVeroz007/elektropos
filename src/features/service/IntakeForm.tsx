import { useState, type FormEvent } from 'react'
import { Link, useNavigate, useSearchParams } from 'react-router-dom'
import { useQuery } from '@tanstack/react-query'
import { Card, ChoiceGroup, ErrorMessage, Loading, Notice, PageHeader, TextArea, TextInput } from '../../components/ui'
import { permissions, useProfile } from '../../lib/session'
import { getTicket, serviceKeys, useServiceCommand } from './api'
import { Button, CommandError } from './common'
import { CustomerPicker, customerChoiceError, type CustomerChoice } from './CustomerPicker'
import { shopLocalToIso } from './logic'
import type { ServiceLocation, TicketDetail } from './types'

type CreateResult = { ticket_id: string; number: string; version: number }

type Form = {
  location: ServiceLocation
  equipmentType: string
  brand: string
  model: string
  serial: string
  complaint: string
  condition: string
  accessories: string
  address: string
  mapLink: string
  scheduledAt: string
}

const EMPTY: Form = {
  location: 'STORE', equipmentType: '', brand: '', model: '', serial: '', complaint: '',
  condition: '', accessories: '', address: '', mapLink: '', scheduledAt: '',
}

/** Kesalahan isian dalam bahasa awam (null bila siap disimpan). */
export function intakeError(form: Form, customer: CustomerChoice | null, hasParent: boolean): string | null {
  if (!hasParent) {
    const customerError = customerChoiceError(customer)
    if (customerError) return customerError
  }
  if (!form.equipmentType.trim()) return 'Jenis alat wajib diisi (mis. TV, kipas angin, pompa air).'
  if (!form.complaint.trim()) return 'Keluhan wajib diisi.'
  if (form.location === 'STORE') {
    if (!form.condition.trim()) return 'Kondisi awal alat wajib dicatat (mis. casing retak, layar gores).'
    if (!form.accessories.trim()) return 'Kelengkapan wajib dicatat. Tulis "Tidak ada" bila hanya unit.'
  } else {
    if (!form.address.trim()) return 'Alamat kunjungan wajib diisi.'
    if (!shopLocalToIso(form.scheduledAt)) return 'Tanggal dan jam kunjungan wajib diisi.'
    if (form.mapLink.trim() && !/^https?:\/\//i.test(form.mapLink.trim())) return 'Tautan peta harus diawali https://'
  }
  return null
}

function buildPayload(form: Form, customer: CustomerChoice | null, parentId: string | null): Record<string, unknown> {
  const payload: Record<string, unknown> = {
    service_location: form.location,
    equipment_type: form.equipmentType.trim(),
    complaint: form.complaint.trim(),
  }
  const optional = (key: string, value: string) => { if (value.trim()) payload[key] = value.trim() }
  optional('equipment_brand', form.brand)
  optional('equipment_model', form.model)
  optional('equipment_serial', form.serial)
  if (parentId) payload.parent_ticket_id = parentId
  else if (customer?.mode === 'existing') payload.customer_id = customer.customer.id
  else if (customer?.mode === 'new') {
    payload.customer_name = customer.draft.name.trim()
    optional('customer_phone', customer.draft.phone)
    optional('customer_alt_contact', customer.draft.alternateContact)
    optional('customer_address', customer.draft.address)
  }
  if (form.location === 'STORE') {
    payload.initial_condition = form.condition.trim()
    payload.accessories = form.accessories.trim()
  } else {
    const map = form.mapLink.trim()
    payload.address = map ? `${form.address.trim()}\nPeta: ${map}` : form.address.trim()
    payload.scheduled_at = shopLocalToIso(form.scheduledAt)
  }
  return payload
}

/** Penerimaan servis (WF-03/WF-04) dan keluhan kembali (WF-07, `?asal=<tiket>`). */
export function IntakeForm() {
  const profile = useProfile()
  const [params] = useSearchParams()
  const parentId = params.get('asal')
  const parent = useQuery({
    queryKey: serviceKeys.ticket(parentId ?? ''),
    queryFn: () => getTicket(parentId ?? ''),
    enabled: Boolean(parentId),
  })
  if (!permissions.receiveService(profile)) {
    return <Notice tone="warning">Akun ini hanya dapat melihat tiket servis.</Notice>
  }
  if (parentId && parent.isPending) return <Loading label="Memuat tiket asal…" />
  if (parentId && parent.isError) return <ErrorMessage error={parent.error} />
  return <IntakeFields parent={parent.data ?? null} key={parent.data?.id ?? 'baru'} />
}

function IntakeFields({ parent }: { parent: TicketDetail | null }) {
  const navigate = useNavigate()
  const [customer, setCustomer] = useState<CustomerChoice | null>(null)
  const [form, setForm] = useState<Form>(() => parent ? {
    ...EMPTY,
    location: parent.service_location,
    equipmentType: parent.equipment_type,
    brand: parent.equipment_brand ?? '',
    model: parent.equipment_model ?? '',
    serial: parent.equipment_serial ?? '',
    address: parent.address ?? '',
  } : EMPTY)
  const [touched, setTouched] = useState(false)
  const create = useServiceCommand<CreateResult, Record<string, unknown>>('create_service_ticket_v1')
  const set = <K extends keyof Form>(key: K) => (value: Form[K]) => setForm(f => ({ ...f, [key]: value }))

  const error = intakeError(form, customer, Boolean(parent))

  async function submit(event: FormEvent) {
    event.preventDefault()
    setTouched(true)
    if (error) return
    const result = await create.run(buildPayload(form, customer, parent?.id ?? null))
    if (result) navigate(`/servis/${result.ticket_id}?foto=1`)
  }

  const onsite = form.location === 'ONSITE'
  const customerAddress = customer?.mode === 'existing' ? customer.customer.address : null

  return (
    <form className="srv-page" onSubmit={submit} noValidate>
      <PageHeader title={parent ? 'Keluhan kembali' : 'Terima servis baru'}
        description={parent
          ? `Tiket baru tertaut ke ${parent.number}. Tiket lama tidak diubah.`
          : 'Isi data pelanggan dan alat. Foto kondisi bisa ditambahkan setelah disimpan.'}
        actions={<Link className="ui-button ui-button-secondary" to={parent ? `/servis/${parent.id}` : '/servis'}>Kembali</Link>} />

      <Card title="1. Pelanggan">
        {parent
          ? <p>Pelanggan sama dengan tiket asal: <strong>{parent.customer?.name ?? '-'}</strong></p>
          : <CustomerPicker value={customer} onChange={setCustomer} />}
      </Card>

      <Card title="2. Alat dan keluhan">
        <ChoiceGroup label="Di mana diperbaiki?" value={form.location} onChange={set('location')} options={[
          { value: 'STORE', label: 'Di toko', description: 'Alat dititipkan di toko' },
          { value: 'ONSITE', label: 'Kunjungan rumah', description: 'Ayah datang ke rumah pelanggan' },
        ]} />
        <TextInput label="Jenis alat" value={form.equipmentType} onChange={set('equipmentType')} required
          placeholder="Mis. TV, kipas angin, pompa air" maxLength={120} />
        <div className="srv-grid-3">
          <TextInput label="Merek (opsional)" value={form.brand} onChange={set('brand')} maxLength={120} />
          <TextInput label="Model (opsional)" value={form.model} onChange={set('model')} maxLength={120} />
          <TextInput label="Nomor seri (opsional)" value={form.serial} onChange={set('serial')} maxLength={120} />
        </div>
        <TextArea label="Keluhan pelanggan" value={form.complaint} onChange={set('complaint')} required maxLength={2000} />
      </Card>

      {onsite ? (
        <Card title="3. Kunjungan">
          <TextArea label="Alamat kunjungan" value={form.address} onChange={set('address')} required rows={2} maxLength={400} />
          {customerAddress && !form.address && (
            <Button variant="secondary" onClick={() => set('address')(customerAddress)}>Pakai alamat pelanggan</Button>
          )}
          <TextInput type="datetime-local" label="Jadwal datang (jam toko)" value={form.scheduledAt}
            onChange={set('scheduledAt')} required />
          <TextInput label="Tautan peta (opsional)" value={form.mapLink} onChange={set('mapLink')}
            placeholder="https://maps.google.com/…" maxLength={80} />
        </Card>
      ) : (
        <Card title="3. Kondisi saat diterima">
          <TextArea label="Kondisi awal alat" value={form.condition} onChange={set('condition')} required
            hint="Catat goresan, retak, bagian hilang. Melindungi toko saat serah terima." maxLength={1000} />
          <TextArea label="Kelengkapan yang dititipkan" value={form.accessories} onChange={set('accessories')} required
            hint='Mis. remote, kabel power, dus. Tulis "Tidak ada" bila hanya unit.' rows={2} maxLength={1000} />
        </Card>
      )}

      {touched && error && <ErrorMessage error={error} />}
      <CommandError error={create.error} />
      <Button type="submit" large disabled={create.busy}>{create.busy ? 'Menyimpan…' : 'Simpan tiket servis'}</Button>
    </form>
  )
}
