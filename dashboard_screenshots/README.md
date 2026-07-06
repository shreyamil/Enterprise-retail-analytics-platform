# Dashboard Screenshots

This folder is intentionally empty in the generated deliverable.

Power BI Desktop is a Windows GUI application and cannot run in the Linux
sandbox used to build this project, so no `.pbix` file could be compiled and
no screenshots could be captured here.

**To populate this folder:** follow `powerbi/data_model.md` and
`powerbi/dashboard_specification.md` to build the 6-page report in Power BI
Desktop (~30–45 minutes for someone following the spec), then export each
page as PNG (File → Export → Export to PDF, or right-click each page →
Export) and drop them here as:

```
dashboard_screenshots/
├── 01_executive_dashboard.png
├── 02_sales_dashboard.png
├── 03_customer_dashboard.png
├── 04_inventory_dashboard.png
├── 05_returns_dashboard.png
└── 06_forecast_dashboard.png
```

Once captured, embed them in the main `README.md` under a "Dashboard
Previews" section for the GitHub-facing version of this project.
