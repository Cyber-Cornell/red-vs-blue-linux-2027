# Incident report: {{incident ID / short title}}

<!-- Adapt to the request and incident stage. Remove unused sections and instructional comments. Keep material unknowns visible. All brace fields are prompts, not facts. -->

| Report control | Value |
| --- | --- |
| Version / status | {{version; draft, situation update, or reviewed final}} |
| Author / reviewer | {{known author; review status}} |
| Report timestamp / information cutoff | {{ISO 8601 timestamps with zone; distinguish them}} |
| Audience / distribution | {{authorized audience, handling restrictions, source TLP if applicable}} |
| Incident status / severity | {{known stage; severity and rubric or unassigned}} |

## Executive summary

{{Known event and its business/scored-service effects, present status, most important uncertainty, and decisions needed. Do not imply confirmed compromise, complete scope, or verified recovery without evidence.}}

## Scope and limitations

{{Systems/services and interval covered; available/missing sources; filtering or collection bounds; unavailable evidence; exclusions; source reliability and time/clock limitations. State actual versus potential impact separately.}}

## Findings and assessment

| ID | Type | Statement | Evidence / precise locator | Confidence, alternatives, or gap |
| --- | --- | --- | --- | --- |
| {{F1}} | {{observed fact / attributed statement / analyst assessment / unknown}} | {{finding}} | {{E1 and line/event/page}} | {{reasoned confidence for assessments; what would resolve uncertainty}} |

{{Root cause, initial access, persistence, affected accounts/data, and attribution only to the extent supported. State significant unknowns explicitly. Indicators need context and observed time; do not imply an IP or domain alone proves maliciousness.}}

## Timeline

Time convention: {{normalization basis; retained source zone; known skew/precision; unresolved assumptions}}.

| Original time / zone | Normalized time, if justified | Event and time type | Source |
| --- | --- | --- | --- |
| {{literal source value}} | {{ISO 8601 or unknown}} | {{event / detection / collection / action; observed or reported}} | {{evidence ID and locator}} |

## Response and recovery

| Action / decision | State | Actor / authority | Time / zone | Result and evidence |
| --- | --- | --- | --- | --- |
| {{action}} | {{proposed / approved / attempted / completed / verified}} | {{known actor and approval reference, or unknown}} | {{time}} | {{actual result; health check and logging check separately}} |

{{Known effects on scored services, remote access, telemetry, and remaining exposure. For closure: criteria, verification coverage/time, unresolved risks, and recorded closure authority.}}

## Next actions and lessons

| Priority | Action / lesson | Owner | Due time / status | Completion criterion |
| --- | --- | --- | --- | --- |
| {{priority and rationale}} | {{next step}} | {{known or proposed}} | {{known, proposed, or unassigned}} | {{observable result}} |

{{For updates, include next reporting time if agreed. Include notifications/coordination only when relevant, clearly marking drafts, approvals, and actual sends.}}

## Evidence register (restricted appendix when needed)

| ID | Source / coverage / locator | Collection time and collector | Method / transformations | Integrity and access |
| --- | --- | --- | --- | --- |
| {{E1}} | {{source; exact coverage; retained artifact reference}} | {{known time/zone and identity, or unknown}} | {{tool/version if known; copy/filter/redaction history}} | {{computed digest and algorithm or not computed; verification basis; restricted storage reference}} |

{{If custody is required, record known transfers with evidence ID, from/to, time/zone, purpose, storage reference, and integrity result. List missing custody history. Keep sensitive mappings outside the distributed report.}}

## Revision and review record

{{Version, change, author/time, reviewer status; preserve prior issued versions and identify corrected conclusions.}}
