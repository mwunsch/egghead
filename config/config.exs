import Config

# Path to the directory where record files live.
# Markdown (.md) and org-mode (.org) files in this directory
# are automatically loaded into the RecordStore index.
config :egghead, :records_dir, Path.expand("../records", __DIR__)

import_config "#{config_env()}.exs"
