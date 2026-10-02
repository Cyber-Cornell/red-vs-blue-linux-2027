# Incident-response reporting research

Verified against primary publisher pages on 2026-10-02. This note supports the project-local `incident-response-report` skill; its Markdown template is a local synthesis, not an official reporting form.

## Publication status and useful guidance

| Primary source | Status observed | Reporting use |
| --- | --- | --- |
| [NIST SP 800-61 Rev. 3 publication record](https://csrc.nist.gov/pubs/sp/800/61/r3/final) and [full publication](https://nvlpubs.nist.gov/nistpubs/SpecialPublications/NIST.SP.800-61r3.pdf) | Final 2025-04-03; April 2025 publication; expressly supersedes Rev. 2. | RS.AN-03 addresses incident analysis; RS.AN-06/07 preserve records and evidence provenance; RS.CO distinguishes coordination, notification, public communication, and sharing; RC.RP-06 calls for an after-action report. |
| [NIST SP 800-86 publication record](https://csrc.nist.gov/pubs/sp/800/86/final) and [full publication](https://nvlpubs.nist.gov/nistpubs/Legacy/SP/nistspecialpublication800-86.pdf) | August 2006 publication; record lists final history as 2006-09-01; no superseding publication is shown on the record. Older supplementary guidance, not the current incident-response lifecycle baseline. | Section 3.4 considers audience, alternative explanations, and actionable results; sections 3.1.2 and 5.1 discuss evidence handling and time context. |
| [FIRST framework landing page](https://www.first.org/standards/frameworks/) and [CSIRT Services Framework v2.1 HTML](https://www.first.org/standards/frameworks/csirts/csirt_services_framework_v2-1) | Landing page lists v2.1 as available/current. HTML labels itself “for review purposes”; preserve that caveat rather than asserting an unqualified final status. | Sections 6.2.2 and 6.3 cover source attribution, tracking, integrity and evidence handling; 6.6.2 covers concise factual status reporting. |
| [FIRST TLP 2.0](https://www.first.org/tlp/) | Publisher identifies v2.0 as current and authoritative from August 2022. | Sharing boundaries follow the source's label; TLP is not a classification system or an encryption/access-control policy. |

## Design decisions

Lead with impact, status, uncertainty, and decisions for leadership; keep technical observations, reasoning, and artifact locators available for responders. NIST's reporting guidance explicitly allows multiple explanations where evidence is incomplete and tailors detail to the audience. Preserve original time context when correlating records. [SP 800-86, sections 3.4 and 5.1](https://nvlpubs.nist.gov/nistpubs/Legacy/SP/nistspecialpublication800-86.pdf)

Maintain an evidence register, record limitations and transformations, and separate proposed actions from observed results. Recovery reporting should identify verification evidence and unresolved work. Formal chain-of-custody is conditional, but evidence integrity and provenance remain relevant in routine incidents. [SP 800-61r3, RS.AN-06/07 and RC.RP-06](https://nvlpubs.nist.gov/nistpubs/SpecialPublications/NIST.SP.800-61r3.pdf)

Catalog sources so later readers can assess their reliability and handling history. Scale the report to the incident, audience, and available facts. The FIRST framework supports a selection of services fitted to a team's mandate, rather than requiring every function for every event. [FIRST CSIRT Services Framework, sections 1, 6.2.2, and 6.6.2](https://www.first.org/standards/frameworks/csirts/csirt_services_framework_v2-1)

The local template therefore offers report control, executive summary, scope/limitations, evidence-linked findings, timeline, response/recovery, follow-ups, and optional evidence/custody detail. Stable IDs, explicit fact/assessment/unknown labels, ISO 8601 time fields, redaction markers, and action-state columns are local implementation choices. Unneeded sections may be removed; material unknowns must remain visible. This reporting workflow does not execute response actions or send notifications.

Redact report copies to the authorized audience while retaining restricted originals. Preserve existing TLP restrictions where supplied; assigning a label does not itself authorize release. [FIRST TLP 2.0, sections 1 and 2](https://www.first.org/tlp/)

## Research limits

The CISA playbook page/PDF could not be retrieved through the browsing tool during this check, so no reporting claim here depends on their contents. No jurisdiction-specific notification deadline or legal sufficiency is asserted. Distro service configuration is outside this documentation-only skill; no ArchWiki/Gentoo operational guidance or host-changing procedures were needed.
