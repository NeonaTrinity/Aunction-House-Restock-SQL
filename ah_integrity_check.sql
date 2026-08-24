-- ============================================================
-- DML Auction House Integrity Check
-- Read-only verification for AzerothCore AH restock/player-sales
--
-- Safe to run at any time, but for a frozen/authoritative snapshot,
-- run while ac-worldserver is STOPPED.
--
-- Expected healthy result:
--   Every summary counter = 0
--   Every detail query = Empty set
-- ============================================================

USE acore_characters;

-- Generated AH seller GUIDs are server-specific. Read them from the
-- same shared configuration used by the restock and player-sale scripts.
SET @fake_seller_1 := (
    SELECT config_value + 0
    FROM custom_ah_restock_config
    WHERE config_key = 'seller_alliance_guid'
);

SET @fake_seller_2 := (
    SELECT config_value + 0
    FROM custom_ah_restock_config
    WHERE config_key = 'seller_horde_guid'
);

-- ============================================================
-- 1. GLOBAL INTEGRITY SUMMARY
-- ============================================================

SELECT
    (SELECT COUNT(*)
     FROM auctionhouse ah
     LEFT JOIN item_instance ii ON ii.guid = ah.itemguid
     WHERE ii.guid IS NULL
    ) AS auctions_missing_item,

    (SELECT COUNT(*)
     FROM character_inventory ci
     LEFT JOIN item_instance ii ON ii.guid = ci.item
     WHERE ii.guid IS NULL
    ) AS inventory_missing_item,

    (SELECT COUNT(*)
     FROM mail_items mi
     LEFT JOIN item_instance ii ON ii.guid = mi.item_guid
     WHERE ii.guid IS NULL
    ) AS mail_items_missing_item,

    (SELECT COUNT(*)
     FROM auctionhouse ah
     JOIN character_inventory ci ON ci.item = ah.itemguid
    ) AS auction_inventory_shared_guids,

    (SELECT COUNT(*)
     FROM auctionhouse ah
     JOIN mail_items mi ON mi.item_guid = ah.itemguid
    ) AS auction_mail_shared_guids,

    (SELECT COUNT(*)
     FROM auctionhouse ah
     JOIN item_instance ii ON ii.guid = ah.itemguid
     WHERE ii.owner_guid <> ah.itemowner
    ) AS auction_owner_mismatches,

    (SELECT COUNT(*)
     FROM (
         SELECT itemguid
         FROM auctionhouse
         GROUP BY itemguid
         HAVING COUNT(*) > 1
     ) duplicate_items
    ) AS duplicate_auction_itemguids,

    (SELECT COUNT(*)
     FROM mail_items mi
     LEFT JOIN mail m ON m.id = mi.mail_id
     WHERE m.id IS NULL
    ) AS mail_items_missing_mail;


-- ============================================================
-- 2. GENERATED AH STOCK SUMMARY
-- Seller GUIDs are read from custom_ah_restock_config
-- ============================================================

SELECT
    (SELECT COUNT(*)
     FROM auctionhouse ah
     LEFT JOIN item_instance ii ON ii.guid = ah.itemguid
     WHERE ah.itemowner IN (@fake_seller_1, @fake_seller_2)
       AND ii.guid IS NULL
    ) AS generated_auctions_missing_item,

    (SELECT COUNT(*)
     FROM auctionhouse ah
     JOIN item_instance ii ON ii.guid = ah.itemguid
     WHERE ah.itemowner IN (@fake_seller_1, @fake_seller_2)
       AND ii.owner_guid <> ah.itemowner
    ) AS generated_owner_mismatches,

    (SELECT COUNT(*)
     FROM auctionhouse ah
     JOIN item_instance ii ON ii.guid = ah.itemguid
     JOIN acore_world.item_template it ON it.entry = ii.itemEntry
     WHERE ah.itemowner IN (@fake_seller_1, @fake_seller_2)
       AND it.MaxDurability > 0
       AND ii.durability <> it.MaxDurability
    ) AS generated_items_bad_durability,

    (SELECT COUNT(*)
     FROM auctionhouse ah
     JOIN item_instance ii ON ii.guid = ah.itemguid
     WHERE ah.itemowner IN (@fake_seller_1, @fake_seller_2)
       AND (ii.enchantments IS NULL OR TRIM(ii.enchantments) = '')
    ) AS generated_empty_enchantments,

    (SELECT COUNT(*)
     FROM auctionhouse ah
     JOIN item_instance ii
       ON ii.guid = ah.itemguid
     JOIN custom_ah_item_pool p
       ON p.item_entry = ii.itemEntry
     JOIN acore_world.item_template it
       ON it.entry = ii.itemEntry
     WHERE ah.itemowner IN (@fake_seller_1, @fake_seller_2)
       AND p.category = 'glyph'
       AND TRIM(ii.charges) <> CONCAT(
           COALESCE(it.spellcharges_1, 0), ' ',
           COALESCE(it.spellcharges_2, 0), ' ',
           COALESCE(it.spellcharges_3, 0), ' ',
           COALESCE(it.spellcharges_4, 0), ' ',
           COALESCE(it.spellcharges_5, 0)
       )
    ) AS glyph_charge_mismatches;


-- ============================================================
-- 3. OVERALL PASS / FAIL
-- PASS means every checked corruption counter is zero.
-- ============================================================

SELECT
CASE
    WHEN
        (SELECT COUNT(*)
         FROM auctionhouse ah
         LEFT JOIN item_instance ii ON ii.guid = ah.itemguid
         WHERE ii.guid IS NULL) = 0

    AND (SELECT COUNT(*)
         FROM character_inventory ci
         LEFT JOIN item_instance ii ON ii.guid = ci.item
         WHERE ii.guid IS NULL) = 0

    AND (SELECT COUNT(*)
         FROM mail_items mi
         LEFT JOIN item_instance ii ON ii.guid = mi.item_guid
         WHERE ii.guid IS NULL) = 0

    AND (SELECT COUNT(*)
         FROM auctionhouse ah
         JOIN character_inventory ci ON ci.item = ah.itemguid) = 0

    AND (SELECT COUNT(*)
         FROM auctionhouse ah
         JOIN mail_items mi ON mi.item_guid = ah.itemguid) = 0

    AND (SELECT COUNT(*)
         FROM auctionhouse ah
         JOIN item_instance ii ON ii.guid = ah.itemguid
         WHERE ii.owner_guid <> ah.itemowner) = 0

    AND (SELECT COUNT(*)
         FROM (
             SELECT itemguid
             FROM auctionhouse
             GROUP BY itemguid
             HAVING COUNT(*) > 1
         ) duplicate_items) = 0

    AND (SELECT COUNT(*)
         FROM mail_items mi
         LEFT JOIN mail m ON m.id = mi.mail_id
         WHERE m.id IS NULL) = 0

    AND (SELECT COUNT(*)
         FROM auctionhouse ah
         JOIN item_instance ii ON ii.guid = ah.itemguid
         JOIN acore_world.item_template it ON it.entry = ii.itemEntry
         WHERE ah.itemowner IN (@fake_seller_1, @fake_seller_2)
           AND it.MaxDurability > 0
           AND ii.durability <> it.MaxDurability) = 0

    AND (SELECT COUNT(*)
         FROM auctionhouse ah
         JOIN item_instance ii ON ii.guid = ah.itemguid
         WHERE ah.itemowner IN (@fake_seller_1, @fake_seller_2)
           AND (ii.enchantments IS NULL OR TRIM(ii.enchantments) = '')) = 0

    AND (SELECT COUNT(*)
         FROM auctionhouse ah
         JOIN item_instance ii ON ii.guid = ah.itemguid
         JOIN custom_ah_item_pool p ON p.item_entry = ii.itemEntry
         JOIN acore_world.item_template it ON it.entry = ii.itemEntry
         WHERE ah.itemowner IN (@fake_seller_1, @fake_seller_2)
           AND p.category = 'glyph'
           AND TRIM(ii.charges) <> CONCAT(
               COALESCE(it.spellcharges_1, 0), ' ',
               COALESCE(it.spellcharges_2, 0), ' ',
               COALESCE(it.spellcharges_3, 0), ' ',
               COALESCE(it.spellcharges_4, 0), ' ',
               COALESCE(it.spellcharges_5, 0)
           )) = 0

    THEN 'PASS - AH integrity checks are clean'
    ELSE 'FAIL - one or more AH integrity checks found a problem'
END AS ah_integrity_status;


-- ============================================================
-- 4. DETAIL QUERIES
-- Healthy database: every query below returns Empty set.
-- ============================================================

-- Auctions pointing to missing item_instance rows.
SELECT
    ah.id AS auction_id,
    ah.itemguid,
    ah.itemowner
FROM auctionhouse ah
LEFT JOIN item_instance ii ON ii.guid = ah.itemguid
WHERE ii.guid IS NULL
ORDER BY ah.id
LIMIT 100;

-- Inventory rows pointing to missing item_instance rows.
SELECT
    ci.guid AS character_guid,
    c.name AS character_name,
    ci.bag,
    ci.slot,
    ci.item AS missing_item_guid
FROM character_inventory ci
LEFT JOIN characters c ON c.guid = ci.guid
LEFT JOIN item_instance ii ON ii.guid = ci.item
WHERE ii.guid IS NULL
ORDER BY ci.guid, ci.bag, ci.slot
LIMIT 100;

-- Auction GUID also referenced by character inventory.
SELECT
    ah.id AS auction_id,
    ah.itemguid,
    ah.itemowner AS auction_owner,
    ci.guid AS inventory_owner,
    ii.itemEntry,
    ii.owner_guid AS item_instance_owner
FROM auctionhouse ah
JOIN character_inventory ci ON ci.item = ah.itemguid
LEFT JOIN item_instance ii ON ii.guid = ah.itemguid
ORDER BY ah.id
LIMIT 100;

-- Auction item owner mismatch.
SELECT
    ah.id AS auction_id,
    ah.itemguid,
    ah.itemowner AS auction_owner,
    ii.owner_guid AS item_instance_owner,
    ii.itemEntry
FROM auctionhouse ah
JOIN item_instance ii ON ii.guid = ah.itemguid
WHERE ii.owner_guid <> ah.itemowner
ORDER BY ah.id
LIMIT 100;

-- Same item GUID referenced by more than one auction.
SELECT
    itemguid,
    COUNT(*) AS auction_count
FROM auctionhouse
GROUP BY itemguid
HAVING COUNT(*) > 1
ORDER BY auction_count DESC, itemguid
LIMIT 100;

-- Generated durable items not at template MaxDurability.
SELECT
    ah.id AS auction_id,
    ii.guid AS itemguid,
    ii.itemEntry,
    it.name,
    ii.durability,
    it.MaxDurability
FROM auctionhouse ah
JOIN item_instance ii ON ii.guid = ah.itemguid
JOIN acore_world.item_template it ON it.entry = ii.itemEntry
WHERE ah.itemowner IN (@fake_seller_1, @fake_seller_2)
  AND it.MaxDurability > 0
  AND ii.durability <> it.MaxDurability
ORDER BY ah.id
LIMIT 100;

-- Generated glyphs whose saved charges do not match item_template.
SELECT
    ah.id AS auction_id,
    ii.guid AS itemguid,
    ii.itemEntry,
    it.name,
    ii.charges AS saved_charges,
    CONCAT(
        COALESCE(it.spellcharges_1, 0), ' ',
        COALESCE(it.spellcharges_2, 0), ' ',
        COALESCE(it.spellcharges_3, 0), ' ',
        COALESCE(it.spellcharges_4, 0), ' ',
        COALESCE(it.spellcharges_5, 0)
    ) AS expected_charges
FROM auctionhouse ah
JOIN item_instance ii ON ii.guid = ah.itemguid
JOIN custom_ah_item_pool p ON p.item_entry = ii.itemEntry
JOIN acore_world.item_template it ON it.entry = ii.itemEntry
WHERE ah.itemowner IN (@fake_seller_1, @fake_seller_2)
  AND p.category = 'glyph'
  AND TRIM(ii.charges) <> CONCAT(
      COALESCE(it.spellcharges_1, 0), ' ',
      COALESCE(it.spellcharges_2, 0), ' ',
      COALESCE(it.spellcharges_3, 0), ' ',
      COALESCE(it.spellcharges_4, 0), ' ',
      COALESCE(it.spellcharges_5, 0)
  )
ORDER BY ah.id
LIMIT 100;
