Rails.application.config.active_record.encryption.primary_key         = ENV.fetch("AR_ENCRYPTION_PRIMARY_KEY",         "a" * 32)
Rails.application.config.active_record.encryption.deterministic_key   = ENV.fetch("AR_ENCRYPTION_DETERMINISTIC_KEY",   "b" * 32)
Rails.application.config.active_record.encryption.key_derivation_salt = ENV.fetch("AR_ENCRYPTION_KEY_DERIVATION_SALT", "c" * 32)
