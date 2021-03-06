ArJdbc.load_java_part :H2
require 'arjdbc/hsqldb/adapter'

module ArJdbc
  module H2
    include HSQLDB

    def self.jdbc_connection_class
      ::ActiveRecord::ConnectionAdapters::H2JdbcConnection
    end

    def self.column_selector
      [ /\.h2\./i, lambda { |cfg, column| column.extend(::ArJdbc::H2::Column) } ]
    end

    module Column

      private

      def extract_limit(sql_type)
        limit = super
        case @sql_type = sql_type.downcase
        # NOTE: JDBC driver f*cks sql_type up with limits (just like HSQLDB) :
        when /^tinyint/i       then @sql_type = 'tinyint'; limit = 1
        when /^smallint|int2/i then @sql_type = 'smallint'; limit = 2
        when /^bigint|int8/i   then @sql_type = 'bigint'; limit = 8
        when /^int|int4/i      then @sql_type = 'int'; limit = 4
        when /^double/i        then @sql_type = 'double'; limit = 8
        when /^real/i          then @sql_type = 'real'; limit = 4
        when /^date/i          then @sql_type = 'date'; limit = nil
        when /^timestamp/i     then @sql_type = 'timestamp'; limit = nil
        when /^time/i          then @sql_type = 'time'; limit = nil
        when /^boolean/i       then @sql_type = 'boolean'; limit = nil
        when /^binary|bytea/i; then @sql_type = 'binary'; limit = 2 * 1024 * 1024
        when /blob|image|oid/i then @sql_type = 'blob'; limit = nil
        when /clob|text/i      then @sql_type = 'clob'; limit = nil
        # NOTE: use lower-case due SchemaDumper not handling it's decimal/integer
        # optimization case-insensitively due : column.type == :integer &&
        # [/^numeric/, /^decimal/].any? { |e| e.match(column.sql_type) }
        when /^decimal\(65535,32767\)/i
          @sql_type = 'decimal'; nil
        end
        limit
      end

      def simplified_type(field_type)
        case field_type
        when /^bit|bool/i         then :boolean
        when /^signed|year/i      then :integer
        when /^real|double/i      then :float
        when /^varchar/i          then :string
        when /^binary|raw|bytea/i then :binary
        when /^blob|image|oid/i   then :binary
        else
          super
        end
      end

      # Post process default value from JDBC into a Rails-friendly format (columns{-internal})
      def default_value(value)
        # H2 auto-generated key default value
        return nil if value =~ /^\(NEXT VALUE FOR/i
        # JDBC returns column default strings with actual single quotes around the value.
        return $1 if value =~ /^'(.*)'$/
        value
      end

    end

    ADAPTER_NAME = 'H2' # :nodoc:

    def adapter_name # :nodoc:
      ADAPTER_NAME
    end

    def self.arel2_visitors(config)
      visitors = HSQLDB.arel2_visitors(config)
      visitors.merge({
        'h2' => ::Arel::Visitors::HSQLDB,
        'jdbch2' => ::Arel::Visitors::HSQLDB,
      })
    end

    # #deprecated
    def h2_adapter # :nodoc:
      true
    end

    NATIVE_DATABASE_TYPES = {
      :primary_key => "bigint identity",
      :boolean     => { :name => "boolean" },
      :tinyint     => { :name => "tinyint", :limit => 1 },
      :smallint    => { :name => "smallint", :limit => 2 },
      :bigint      => { :name => "bigint", :limit => 8 },
      :integer     => { :name => "int", :limit => 4 },
      :decimal     => { :name => "decimal" },
      :float       => { :name => "float", :limit => 8 },
      :double      => { :name => "double", :limit => 8 },
      :real        => { :name => "real", :limit => 4 },
      :date        => { :name => "date" },
      :time        => { :name => "time" },
      :timestamp   => { :name => "timestamp" },
      :binary      => { :name => "binary" },
      :string      => { :name => "varchar", :limit => 255 },
      :char        => { :name => "char" },
      :blob        => { :name => "blob" },
      :text        => { :name => "clob" },
      :clob        => { :name => "clob" },
      :uuid        => { :name => "uuid" },
      :other       => { :name => "other" }, # java.lang.Object
      :array       => { :name => "array" }, # java.lang.Object[]
      :varchar_casesensitive => { :name => 'VARCHAR_CASESENSITIVE' },
      :varchar_ignorecase => { :name => 'VARCHAR_IGNORECASE' },
    }

    def native_database_types
      NATIVE_DATABASE_TYPES.dup
    end

    def modify_types(types)
      types
    end

    def type_to_sql(type, limit = nil, precision = nil, scale = nil)
      case type.to_sym
      when :integer
        case limit
        when 1; 'tinyint'
        when 2; 'smallint'
        when nil, 3, 4; 'int'
        when 5..8; 'bigint'
        else raise(ActiveRecordError, "No integer type has byte size #{limit}")
        end
      when :float
        case limit
        when 1..4; 'real'
        when 5..8; 'double'
        else raise(ActiveRecordError, "No float type has byte size #{limit}")
        end
      when :binary
        if limit && limit < 2 * 1024 * 1024
          'binary'
        else
          'blob'
        end
      else
        super
      end
    end

    def tables
      @connection.tables(nil, h2_schema)
    end

    def columns(table_name, name = nil)
      @connection.columns_internal(table_name.to_s, nil, h2_schema)
    end

    def change_column(table_name, column_name, type, options = {}) #:nodoc:
      execute "ALTER TABLE #{table_name} ALTER COLUMN #{column_name} #{type_to_sql(type, options[:limit])}"
      change_column_default(table_name, column_name, options[:default]) if options_include_default?(options)
      change_column_null(table_name, column_name, options[:null], options[:default]) if options.key?(:null)
    end

    def current_schema
      execute('CALL SCHEMA()')[0].values[0]
    end

    def quote(value, column = nil) # :nodoc:
      case value
      when String
        if value.empty?
          "''"
        else
          super
        end
      else
        super
      end
    end

    # EXPLAIN support :

    def supports_explain?; true; end

    def explain(arel, binds = [])
      sql = "EXPLAIN #{to_sql(arel, binds)}"
      raw_result  = execute(sql, "EXPLAIN", binds)
      raw_result[0].values.join("\n") # [ "SELECT \n ..." ].to_s
    end

    private

    def change_column_null(table_name, column_name, null, default = nil)
      if !null && !default.nil?
        execute("UPDATE #{table_name} SET #{column_name}=#{quote(default)} WHERE #{column_name} IS NULL")
      end
      if null
        execute "ALTER TABLE #{table_name} ALTER COLUMN #{column_name} SET NULL"
      else
        execute "ALTER TABLE #{table_name} ALTER COLUMN #{column_name} SET NOT NULL"
      end
    end

    def h2_schema
      @config[:schema] || ''
    end

  end
end
