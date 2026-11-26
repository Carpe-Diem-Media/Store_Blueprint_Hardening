# Governance: Tax & Shipping Determinism (Authoritative)
Tax and shipping computation is where stores leak pennies and drift across projects. This document pins determinism rules.

## 1) Principles (MUST)
1) Tax and shipping MUST be computed deterministically from explicit inputs.
2) No wall-clock dependency: computations take an explicit `as_of` timestamp.
3) All money values are integer minor units only.
4) Results MUST be fully auditable: store inputs and outputs (snapshot evidence).

## 2) Shipping model (baseline)
### 2.1 Shipping rate sources (single-tenant baseline)
- flat_rate
- weight_based (optional)
- destination_zone_based (optional)
- free_shipping threshold / coupon overrides (optional)

A project must pick which are enabled; do not allow ad-hoc combinations without governance updates.

### 2.2 Deterministic selection (MUST)
If multiple shipping rates match:
1) select the lowest shipping_cost_minor
2) tie-break by stable rate_id UUID binary sort using a non-raising normalization path
3) if still tie, stable code string sort

### 2.3 Shipping evidence (MUST)
Orders must store:
- selected shipping rate id/code
- shipping_cost_minor_original snapshot
- shipping_cost_minor_effective snapshot
- free_shipping_applied flag
- free_shipping_reason
- destination fields used for calculation (scrubbed/minimal)

## 3) Tax model (baseline)
### 3.1 Tax jurisdiction inputs (single-tenant baseline)
Tax computation inputs must be explicit:
- destination country/region (or none if tax not used)
- product tax category (if used)
- tax rate table effective window

For an order containing only products classified as digital downloads, use the
buyer’s billing country and region. Store records these separately from the
shipping address. A digital-only order has no shipping quote, shipping tax, or
shipping charge. A mixed cart still uses its shipping destination for tax and
requires a shipping quote for the physical items.

### 3.2 Deterministic tax calculation (MUST)
- Compute per line item tax from priced snapshot evidence (`net_line_total_minor`, post-discount).
- Use round half up at the line level to minor units.
- Order-level tax is sum of line taxes + shipping tax (if taxable), no recomputation.

### 3.3 Tax evidence (MUST)
Orders must store:
- tax_total_minor snapshot
- per-line tax breakdown (if required)
- tax rate identifiers used (optional but recommended)

## 4) Allocation and rounding (MUST)
- No floats.
- If allocating order-level shipping discounts or tax adjustments:
  - allocate proportionally
  - distribute remainder pennies deterministically by UUID binary sort

## 5) Error semantics (MUST)
- INVALID_ADDRESS: missing/invalid destination fields for enabled shipping/tax
- SHIPPING_RATE_NOT_FOUND: no eligible shipping rate
- TAX_RATE_NOT_FOUND: tax enabled but no applicable rate
- VALIDATION_ERROR: bad inputs

## 6) Test gates (MUST)
1) Determinism: same inputs => identical shipping/tax outputs.
2) Tie-breaks: multiple matching rates => deterministic selection.
3) Rounding: no penny leak; totals match sum of parts.
4) Evidence: order snapshot stores chosen rate and tax amounts, and they don’t change later.

## 7) Drift protocol (MUST)
Update this doc + tests before changing behavior.
