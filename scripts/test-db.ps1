#!/usr/bin/env pwsh

$ErrorActionPreference = "Stop"

Write-Host "Running DB Tests (P0 & P1)" -ForegroundColor Cyan

Write-Host "Resetting test DB..."
psql -h 127.0.0.1 -p 54329 -U postgres -tAc "DROP SCHEMA IF EXISTS private CASCADE; DROP SCHEMA IF EXISTS auth CASCADE;"

Write-Host "Running bootstrap..."
psql -h 127.0.0.1 -p 54329 -U postgres -v ON_ERROR_STOP=1 -f supabase/local-test/bootstrap.sql

Write-Host "Running migrations..."
$migrations = Get-ChildItem supabase/migrations -Filter *.sql | Sort-Object Name
foreach ($m in $migrations) {
    Write-Host "  - $($m.Name)"
    psql -h 127.0.0.1 -p 54329 -U postgres -v ON_ERROR_STOP=1 -f $m.FullName
}

Write-Host "Seeding..."
psql -h 127.0.0.1 -p 54329 -U postgres -v ON_ERROR_STOP=1 -f supabase/seed.sql

Write-Host "Running AT-01/AT-02 Tests..."

$ownerRole = psql -h 127.0.0.1 -p 54329 -U postgres -tAc "set request.jwt.claim.sub = '11111111-1111-4111-8111-111111111111'; set role authenticated; SELECT public.get_current_profile_v1() ->> 'role';"
if ($ownerRole -ne "OWNER") { throw "Expected OWNER, got $ownerRole" }
Write-Host "  Owner profile: PASS"

Write-Host "Testing AT-02: Staff cannot write product..."
$staffWrite = psql -h 127.0.0.1 -p 54329 -U postgres -tAc "set request.jwt.claim.sub = '22222222-2222-4222-8222-222222222222'; set role authenticated; SELECT public.upsert_product_v1('{""operation_id"":""99999999-9999-9999-9999-999999999999"",""sku"":""X"",""name"":""X"",""base_unit"":""pcs"",""quantity_step"":""1"",""track_segments"":false,""unit_label"":""pcs"",""factor_base"":""1"",""sale_step"":""1"",""sell_price"":""1000""}'::jsonb);"
if ($staffWrite -notmatch "Hanya owner") { throw "Staff should not upsert product: $staffWrite" }
Write-Host "  Staff write blocked: PASS"

Write-Host "Testing AT-02: Staff cannot read cost..."
$ownerProd = psql -h 127.0.0.1 -p 54329 -U postgres -tAc "set request.jwt.claim.sub = '11111111-1111-4111-8111-111111111111'; set role authenticated; SELECT public.get_product_v1('{""product_id"":""aaaaa111-1111-4111-8111-111111111111""}'::jsonb);"
if ($ownerProd -notmatch "lots") { throw "Owner should see lots" }

$staffProd = psql -h 127.0.0.1 -p 54329 -U postgres -tAc "set request.jwt.claim.sub = '22222222-2222-4222-8222-222222222222'; set role authenticated; SELECT public.get_product_v1('{""product_id"":""aaaaa111-1111-4111-8111-111111111111""}'::jsonb);"
if ($staffProd -match "lots") { throw "Staff should not see lots" }
Write-Host "  Cost hidden from staff: PASS"

Write-Host "Testing AT-01: Disabled account blocked..."
$disabledErr = psql -h 127.0.0.1 -p 54329 -U postgres -tAc "set request.jwt.claim.sub = '44444444-4444-4444-8444-444444444444'; set role authenticated; SELECT public.get_current_profile_v1();" 2>&1
if ($disabledErr -notmatch "ditolak") { throw "Disabled user should be denied: $disabledErr" }
Write-Host "  Disabled blocked: PASS"

Write-Host "Testing AT-15: Opening Stock..."
$openingPayload = '{"operation_id":"88888888-8888-8888-8888-888888888888","reason":"Stok Awal","items":[{"product_unit_id":"u1111111-1111-4111-8111-111111111111","qty":"10","acquisition_cost":"100000","note":"Lampu 10 pcs"},{"product_unit_id":"u2222222-2222-4222-8222-222222222222","qty":"150","acquisition_cost":"450000","note":"Kabel 150m","positions":[{"qty_base":"100","segment_capacity":"100","sealed":true,"label":"R001"},{"qty_base":"50","segment_capacity":"100","sealed":false,"label":"R002"}]}]}'

$openRes = psql -h 127.0.0.1 -p 54329 -U postgres -tAc "set request.jwt.claim.sub = '11111111-1111-4111-8111-111111111111'; set role authenticated; SELECT public.post_opening_stock_v1('$openingPayload'::jsonb);"
if ($openRes -notmatch '"ok"') { throw "Opening stock failed: $openRes" }
Write-Host "  Opening stock posted: PASS"

# Idempotency
$openRes2 = psql -h 127.0.0.1 -p 54329 -U postgres -tAc "set request.jwt.claim.sub = '11111111-1111-4111-8111-111111111111'; set role authenticated; SELECT public.post_opening_stock_v1('$openingPayload'::jsonb);"
if ($openRes -ne $openRes2) { throw "Idempotency failed" }
Write-Host "  Idempotency: PASS"

Write-Host "Testing AT-16: Transfer Stock..."
$posId = psql -h 127.0.0.1 -p 54329 -U postgres -tAc "SELECT id FROM private.stock_positions WHERE label='R002'"
$tfPayload = '{""operation_id"":"77777777-7777-7777-7777-777777777777"",""position_id"":""' + $posId + '"",""expected_version"":1,""qty_base"":""20"",""destination_location"":""FIELD_FATHER"",""destination_label"":""R002-FIELD"",""reason"":""Dibawa kunjungan""}'
$tfRes = psql -h 127.0.0.1 -p 54329 -U postgres -tAc "set request.jwt.claim.sub = '11111111-1111-4111-8111-111111111111'; set role authenticated; SELECT public.transfer_stock_v1('$tfPayload'::jsonb);"
if ($tfRes -notmatch '"ok"') { throw "Transfer failed: $tfRes" }

$shopQty = psql -h 127.0.0.1 -p 54329 -U postgres -tAc "SELECT coalesce(sum(qty_base),0)::int FROM private.stock_positions WHERE location='SHOP' AND label='R002'"
$fieldQty = psql -h 127.0.0.1 -p 54329 -U postgres -tAc "SELECT coalesce(sum(qty_base),0)::int FROM private.stock_positions WHERE location='FIELD_FATHER' AND label='R002-FIELD'"
if ([int]$shopQty -ne 30) { throw "Shop Qty should be 30, got $shopQty" }
if ([int]$fieldQty -ne 20) { throw "Field Qty should be 20, got $fieldQty" }
Write-Host "  Transfer + inventory: PASS"

Write-Host ""
Write-Host "=== All DB tests passed ===" -ForegroundColor Green
Write-Host "  AT-01: Auth & multi-role - PASS"
Write-Host "  AT-02: Hak akses API langsung - PASS"
Write-Host "  AT-15: Opening stock & idempotency - PASS"
Write-Host "  AT-16: Transfer stock - PASS"
