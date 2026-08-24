-- ============================================================
-- DML Auction House - Destination Server Configuration
--
-- This file is SAFE TO RE-RUN.
--
-- It does NOT recreate the market tables.
-- It only resolves the configured seller character names to GUIDs
-- and updates destination-specific AH settings.
--
-- The maintenance runner can edit the two seller-name SET lines
-- below automatically during Install / Reconfigure.
-- ============================================================

USE acore_characters;

-- ============================================================
-- SELLER NAMES
-- The runner updates these automatically.
-- Manual users may edit them directly.
-- Character names should match real characters that have logged in.
-- ============================================================

SET @seller_alliance_name := 'Auctionally';
SET @seller_horde_name    := 'Auctionhorde';

-- ============================================================
-- DESTINATION SETTINGS
-- ============================================================

SET @use_both_sellers := 1;

-- 7 = Neutral AH.
-- Recommended with:
--   AllowTwoSide.Interaction.Auction = 1
SET @auction_house_id := 7;

-- 48 hours.
SET @auction_duration_seconds := 172800;

-- 100 copper = 1 silver.
SET @default_deposit := 100;

-- ============================================================
-- VALIDATION
-- ============================================================

SET @seller_alliance_guid := (
    SELECT guid
    FROM characters
    WHERE name = @seller_alliance_name
    LIMIT 1
);

SET @seller_horde_guid := (
    SELECT guid
    FROM characters
    WHERE name = @seller_horde_name
    LIMIT 1
);

DROP PROCEDURE IF EXISTS dml_ah_validate_destination_config;

DELIMITER $$

CREATE PROCEDURE dml_ah_validate_destination_config()
BEGIN
    IF @seller_alliance_guid IS NULL THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Alliance AH seller character was not found. Check seller name.';
    END IF;

    IF @seller_horde_guid IS NULL THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Horde AH seller character was not found. Check seller name.';
    END IF;

    IF @seller_alliance_guid = @seller_horde_guid THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'The two AH seller names resolve to the same character.';
    END IF;

    IF @auction_house_id NOT IN (2, 6, 7) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Unsupported auction_house_id. Use 2, 6, or 7.';
    END IF;
END$$

DELIMITER ;

CALL dml_ah_validate_destination_config();
DROP PROCEDURE dml_ah_validate_destination_config;

-- ============================================================
-- WRITE / UPDATE CONFIG
-- Re-running this replaces the old destination seller settings.
-- ============================================================

INSERT INTO custom_ah_restock_config (config_key, config_value)
VALUES
    ('seller_alliance_name', @seller_alliance_name),
    ('seller_alliance_guid', @seller_alliance_guid),
    ('seller_horde_name', @seller_horde_name),
    ('seller_horde_guid', @seller_horde_guid),
    ('use_both_sellers', @use_both_sellers),
    ('auction_house_id', @auction_house_id),
    ('auction_duration_seconds', @auction_duration_seconds),
    ('default_deposit', @default_deposit)
ON DUPLICATE KEY UPDATE
    config_value = VALUES(config_value);

-- Old/private builds stored seller GUIDs in the simulated-sales table.
-- The portable scripts use custom_ah_restock_config as the single source
-- of truth, so remove stale duplicate seller settings if they exist.
DELETE FROM custom_ah_simulated_sales_config
WHERE config_key IN ('seller_alliance_guid', 'seller_horde_guid');

-- ============================================================
-- VERIFICATION
-- ============================================================

SELECT
    c.guid,
    c.name,
    c.race,
    c.class
FROM characters c
WHERE c.guid IN (@seller_alliance_guid, @seller_horde_guid)
ORDER BY c.guid;

SELECT config_key, config_value
FROM custom_ah_restock_config
WHERE config_key IN (
    'seller_alliance_name',
    'seller_alliance_guid',
    'seller_horde_name',
    'seller_horde_guid',
    'use_both_sellers',
    'auction_house_id',
    'auction_duration_seconds',
    'default_deposit'
)
ORDER BY config_key;

SELECT 'AH destination configuration complete' AS status;
