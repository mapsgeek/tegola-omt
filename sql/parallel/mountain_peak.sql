DO $$ BEGIN RAISE NOTICE 'Processing layer mountain_peak'; END$$;

-- Layer mountain_peak - ./update_peak_point.sql

DROP TRIGGER IF EXISTS trigger_flag ON osm_peak_point;
DROP TRIGGER IF EXISTS trigger_store ON osm_peak_point;
DROP TRIGGER IF EXISTS trigger_refresh ON mountain_peak_point.updates;

CREATE SCHEMA IF NOT EXISTS mountain_peak_point;

CREATE TABLE IF NOT EXISTS mountain_peak_point.osm_ids
(
    osm_id bigint
);

-- etldoc:  osm_peak_point ->  osm_peak_point
CREATE OR REPLACE FUNCTION update_osm_peak_point(full_update boolean) RETURNS void AS
$$
    UPDATE osm_peak_point
    SET tags = update_tags(tags, geometry)
    WHERE (full_update OR osm_id IN (SELECT osm_id FROM mountain_peak_point.osm_ids))
      AND COALESCE(tags -> 'name:latin', tags -> 'name:nonlatin', tags -> 'name_int') IS NULL
      AND tags != update_tags(tags, geometry)
$$ LANGUAGE SQL;

SELECT update_osm_peak_point(true);

-- Handle updates

CREATE OR REPLACE FUNCTION mountain_peak_point.store() RETURNS trigger AS
$$
BEGIN
    IF (tg_op = 'DELETE') THEN
        INSERT INTO mountain_peak_point.osm_ids VALUES (OLD.osm_id);
    ELSE
        INSERT INTO mountain_peak_point.osm_ids VALUES (NEW.osm_id);
    END IF;
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE TABLE IF NOT EXISTS mountain_peak_point.updates
(
    id serial PRIMARY KEY,
    t  text,
    UNIQUE (t)
);
CREATE OR REPLACE FUNCTION mountain_peak_point.flag() RETURNS trigger AS
$$
BEGIN
    INSERT INTO mountain_peak_point.updates(t) VALUES ('y') ON CONFLICT(t) DO NOTHING;
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION mountain_peak_point.refresh() RETURNS trigger AS
$$
DECLARE
    t TIMESTAMP WITH TIME ZONE := clock_timestamp();
BEGIN
    RAISE LOG 'Refresh mountain_peak_point';
    PERFORM update_osm_peak_point(false);
    -- noinspection SqlWithoutWhere
    DELETE FROM mountain_peak_point.osm_ids;
    -- noinspection SqlWithoutWhere
    DELETE FROM mountain_peak_point.updates;

    RAISE LOG 'Refresh mountain_peak_point done in %', age(clock_timestamp(), t);
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trigger_store
    AFTER INSERT OR UPDATE OR DELETE
    ON osm_peak_point
    FOR EACH ROW
EXECUTE PROCEDURE mountain_peak_point.store();

CREATE TRIGGER trigger_flag
    AFTER INSERT OR UPDATE OR DELETE
    ON osm_peak_point
    FOR EACH STATEMENT
EXECUTE PROCEDURE mountain_peak_point.flag();

CREATE CONSTRAINT TRIGGER trigger_refresh
    AFTER INSERT
    ON mountain_peak_point.updates
    INITIALLY DEFERRED
    FOR EACH ROW
EXECUTE PROCEDURE mountain_peak_point.refresh();

-- Layer mountain_peak - ./mountain_peak.sql

-- etldoc: layer_mountain_peak[shape=record fillcolor=lightpink,
-- etldoc:     style="rounded,filled", label="layer_mountain_peak | <z7_> z7+" ] ;

CREATE OR REPLACE FUNCTION layer_mountain_peak(bbox geometry,
                                               zoom_level integer,
                                               pixel_width numeric)
    RETURNS TABLE
            (
                osm_id   bigint,
                geometry geometry,
                name     text,
                name_en  text,
                name_de  text,
                class    text,
                tags     hstore,
                ele      int,
                ele_ft   int,
                "rank"   int
            )
AS
$$
SELECT
    -- etldoc: osm_peak_point -> layer_mountain_peak:z7_
    osm_id,
    geometry,
    name,
    name_en,
    name_de,
    tags->'natural' AS class,
    tags,
    ele::int,
    ele_ft::int,
    rank::int
FROM (
         SELECT osm_id,
                geometry,
                name,
                COALESCE(NULLIF(name_en, ''), name) AS name_en,
                COALESCE(NULLIF(name_de, ''), name, name_en) AS name_de,
                tags,
                substring(ele FROM E'^(-?\\d+)(\\D|$)')::int AS ele,
                round(substring(ele FROM E'^(-?\\d+)(\\D|$)')::int * 3.2808399)::int AS ele_ft,
                row_number() OVER (
                    PARTITION BY LabelGrid(geometry, 100 * pixel_width)
                    ORDER BY (
                            substring(ele FROM E'^(-?\\d+)(\\D|$)')::int +
                            (CASE WHEN NULLIF(wikipedia, '') IS NOT NULL THEN 10000 ELSE 0 END) +
                            (CASE WHEN NULLIF(name, '') IS NOT NULL THEN 10000 ELSE 0 END)
                        ) DESC
                    )::int AS "rank"
         FROM osm_peak_point
         WHERE geometry && bbox
           AND ele IS NOT NULL
           AND ele ~ E'^-?\\d{1,4}(\\D|$)'
     ) AS ranked_peaks
WHERE zoom_level >= 7
  AND (rank <= 5 OR zoom_level >= 14)
ORDER BY "rank" ASC;

$$ LANGUAGE SQL STABLE
                PARALLEL SAFE;
-- TODO: Check if the above can be made STRICT -- i.e. if pixel_width could be NULL

DO $$ BEGIN RAISE NOTICE 'Finished layer mountain_peak'; END$$;
