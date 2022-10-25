CREATE SCHEMA pgmq;
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

create table pgmq.migrations (
    current_revision smallint not null
);

INSERT INTO pgmq.migrations VALUES (0);

create table pgmq.queues (
    id serial primary key,
    name text not null,
    UNIQUE(name),
    ack_deadline interval not null,
    max_delivery_attempts integer not null,
    retention_period interval not null,
    -- statistics
    current_message_count integer not null DEFAULT 0, -- current number of messages in the queue
    undelivered_message_count integer not null DEFAULT 0 -- number of messages that have never been delivered
);

create table pgmq.messages (
    queue_id bigserial references pgmq.queues on delete cascade not null,
    id uuid, -- generated by app so it can start waiting for results before publishing
    PRIMARY KEY(queue_id, id),
    expires_at timestamp not null,
    delivery_attempts integer not null,
    available_at timestamp not null,
    body bytea not null
) PARTITION BY LIST(queue_id);


CREATE OR REPLACE FUNCTION pgmq.create_message_partitions() RETURNS trigger AS
$$
DECLARE
    messages_partition_table_name text;
BEGIN
    messages_partition_table_name :=  'pgmq.messages_' || NEW.id::text;
    EXECUTE format(
        'CREATE TABLE %I PARTITION OF pgmq.messages FOR VALUES IN (%L);',
        messages_partition_table_name,
        NEW.id
    );
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER "pgmq.create_message_partitions"
AFTER INSERT ON pgmq.queues FOR EACH ROW
EXECUTE PROCEDURE pgmq.create_message_partitions();

CREATE OR REPLACE FUNCTION pgmq.drop_messages_partitions() RETURNS trigger AS
$$
DECLARE
    messages_partition_table_name text;
BEGIN
    messages_partition_table_name :=  'pgmq.messages_' || OLD.id::text;
    EXECUTE format(
        'DROP TABLE %I CASCADE;',
        messages_partition_table_name
    );
    RETURN OLD;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER "pgmq.drop_messages_partitions"
AFTER DELETE ON pgmq.queues FOR EACH ROW
EXECUTE PROCEDURE pgmq.drop_messages_partitions();


create table pgmq.queue_link_types(
    id serial primary key,
    name text not null,
    UNIQUE(name)
);

-- TODO: fan-out, reply-to?
INSERT INTO pgmq.queue_link_types(name)
VALUES ('dlq'), ('completed');

create table pgmq.queue_links(
    id serial primary key,
    parent_id serial references pgmq.queues on delete cascade not null,
    link_type_id serial references pgmq.queue_link_types on delete cascade not null,
    child_id serial references pgmq.queues on delete cascade not null,
    UNIQUE(parent_id, link_type_id, child_id)
);

CREATE OR REPLACE FUNCTION pgmq.drop_children() RETURNS trigger AS
$$
DECLARE
    messages_partition_table_name text;
BEGIN
    WITH deleted_links AS (
        DELETE FROM pgmq.queue_links
        WHERE parent_id = OLD.id
        RETURNING child_id
    )
    DELETE FROM pgmq.queues
    WHERE id IN (SELECT child_id FROM deleted_links);
    RETURN OLD;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER "pgmq.drop_children"
BEFORE DELETE ON pgmq.queues FOR EACH ROW
EXECUTE PROCEDURE pgmq.drop_children();

-- Index for ackinc/nacknig messages within a partition
CREATE INDEX "pgmq.messages_id_idx" ON pgmq.messages(id);

-- Indexes for looking for expired messages and available messages
CREATE INDEX "pgmq.messages_available_idx"
ON pgmq.messages(available_at);

CREATE INDEX "pgmq.messages_expiration_idx"
ON pgmq.messages(delivery_attempts, expires_at);


CREATE FUNCTION pgmq.cleanup_dead_messages()
    RETURNS VOID
    LANGUAGE sql AS
$$
    DELETE
    FROM pgmq.messages
    USING pgmq.queues
    WHERE (
        pgmq.queues.id = pgmq.messages.queue_id
        AND
        available_at < now()
        AND (
            expires_at < now()
            OR
            delivery_attempts >= max_delivery_attempts
        )
    );
$$;
