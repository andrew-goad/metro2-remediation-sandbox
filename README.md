# Metro 2 Remediation Sandbox: Synthetic Portfolio & Impact Engine 📊💎

**How do you simulate high-stakes regulatory credit repairs without risking PII or compromising reporting integrity?** This modular PostgreSQL engine features a synthetic longitudinal tradeline generator (24-month PHP), a dynamic impact resolution engine, and audit-ready "Before & After" reporting.

---

![Metro 2 Remediation Sandbox Dashboard](https://github.com/andrew-goad/metro2-remediation-sandbox/blob/main/docs/executive_dashboard_preview.png)

---

## 🎯 Executive "Talk Tracks"

* **🛡️ The "Cure" Philosophy:** We define a behavioral cure not by a single status change, but by a sustained, **N-month streak of '0' (Current) markers** in the Payment History Profile (PHP) post financial remediation impact window. This ensures the credit reporting remediation window accurately reflects a consumer's return to stability, providing a defensible "Recovery Point" that stands up to 3rd-line audit. No-Cure situations are treated through execution and flagged for ongoing monitoring.
* **⚖️ Defending the "Recovery":** Includes a strategic **"No-Delete" override** for accounts with post-derogatory recovery evidence. This moves beyond blunt "wipe" logic to a nuanced, customer-centric approach that protects favorable consumer reporting and maintains corporate social responsibility.
* **🤝 The "No Cold Handoffs" Promise:** Despite the technical complexity, the output visualizes the translation of raw SQL logic into boardroom-ready remediation impact signals and treatment personas, providing a transparent "Why" for Finance, Legal, and Risk stakeholders.
* **🚦 Risk Mitigation:** By allowing for the simulation of complex Metro 2 remediation strategies in a synthetic environment *before* production implementation, this engine significantly reduces **FCRA reporting risk** and prevents systemic data corruption in live bureau reporting.

---

## 🛠️ Technical Rigor & Architecture

* **🧱 Module 1: Longitudinal Tradeline Sample Builder:** Replaces iterative PHP explosion with a month-level status history materialization, establishing a "central truth" source. Synthesizes multi-year behavioral cycles across diverse risk profiles (e.g., reversed major derogatories, chronic delinquents) without exposing PII.
* **⚙️ Module 2: Credit Impact Window & Remediation Engine:** A dynamic evaluator that maps financial remediation windows against credit reporting cycles. It automates complex account-state corrections (PHP, Status 17A, Payment Rating 17B, and DOFD) using the N-month PHP '0' stability threshold.
* **🔍 Forensic Auditing:** Built-in data integrity gates, including **16+ specific QA checks**, to validate that the synthetic behavioral "truth" exactly matches the final reported "artifact."

---

## 🧩 Modular Integration

Designed as a plug-and-play **"Remediation Strategy Sandbox"** for any enterprise ETL pipeline or regulatory environment. This framework allows leadership to test "what-if" scenarios—such as varying the N-month cure threshold—to quantify the impact on consumer populations before a single record is updated in the system of record.

---

### 🚀 How to Run the Sandbox

1.  **Execute Module 1:** Run `src/module_01_metro2_synthetic_portfolio_generator.sql` to build the behavioral backbone and status history.
2.  **Execute Module 2:** Run `src/module_02_metro2_remediation_engine.sql` to apply the remediation treatments and generate the audit-ready final state.
3.  **Review QA:** Inspect the final `metro2_remediation_final` table to view the "Before vs. After" delta.

---

### 🔒 Integrity & Confidentiality Note
**Data Privacy:** All data and visual outputs in this repository are generated from synthetic or anonymized datasets to protect proprietary information. This framework demonstrates the methodology applied to high-stakes enterprise and regulatory environments.

---
**Philosophy:** **“No Cold Handoffs”**—engineering zero-defect, audit-ready results to ensure stakeholders internalize the underlying “why.”
