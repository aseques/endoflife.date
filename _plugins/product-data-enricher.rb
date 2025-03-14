# This plugin enriches the product pages by setting or precomputing its metadata, so that it can be
# easily consumed in layouts or plugins (such as the API v1 plugin).
#
# Naming conventions:
# - Raw fields, declared in product's markdown front matter or derived from a template (such as the
#   changelogTemplate), use the camel case notation (example: endOfLife).
# - Computed fields, injected by ProductDataEnricher, use the snake case notation (example: end_of_life).
#
# Here is a list of computed fields :
# - is_maintained (in cycles) : whether the product cycle is still supported (mandatory)
# - can_be_hidden (in cycles) : whether the product cycle can be hidden when displaying the product page (mandatory)
# - is_lts (in cycles) : whether the product cycle is currently in its LTS phase (mandatory)
# - lts_from (in cycles) : the LTS phase start date for the product cycle (optional, only if lts is a Date)
# - is_active_support_over (in cycles) : whether the product cycle has reach the end of active support (optional, only if support is set)
# - active_support_until (in cycles) : end of the product cycle support phase date (optional, only if support is set to a Date)
# - is_eol (in cycles) : whether the product cycle is currently eol (optional, only if eol is set)
# - eol_from (in cycles) : EOL date of the product cycle (optional, only if eol is set to a Date)
# - is_discontinued (in cycles) : whether the product cycle is currently discontinued (optional, only if discontinued is set)
# - discontinued_from (in cycles) : discontinuation date of the product cycle (optional, only if discontinued is set to a Date)
# - is_extended_support_over (in cycles) : whether the product cycle has reach the end of extended support (optional, only if extendedSupport is set)
# - extended_support_until (in cycles) : end of the product cycle extended support phase date (optional, only if extendedSupport is set to a Date)
# - days_toward_support (in cycles) : number of days toward the end of support for the cycle (optional, only if support is set)
# - days_toward_eol (in cycles) : number of days toward the EOL of the cycle (optional, only if eol is set)
# - days_toward_discontinued (in cycles) : number of days toward the discontinuation of the cycle (optional, only if discontinued is set)
# - days_toward_extendedSupport (in cycles) : number of days toward the end of extended support for the cycle (optional, only if extendedSupport is set)
module Jekyll
  class ProductDataEnricher
    class << self

      TOPIC = "EndOfLife Product Data Enricher:"

      def enrich(page)
        Jekyll.logger.debug TOPIC, "Enriching #{page.name}"

        set_id(page)
        set_description(page)
        set_icon_url(page)
        set_tags(page)
        set_overridden_columns_label(page)

        page.data["releases"].each { |release| enrich_release(page, release) }

        # DO NOT MOVE : below methods need information computed by enrich_release.
        flag_oldest_unmaintained_releases(page)
      end

      def is_product?(page)
        page.data['layout'] == 'product'
      end

      private

      # Build the product id from the permalink.
      def set_id(page)
        page.data['id'] = page.data['permalink'][1..page.data['permalink'].length]
      end

      # Build the product description, if it's not already set in the product's front matter.
      def set_description(page)
        if !page.data['description']
          page.data['description'] = "Check end-of-life, release policy and support schedule for #{page.data['title']}."
        end
      end

      # Build the icon URL from the icon slug.
      def set_icon_url(page)
        if page['iconSlug']
          page.data['iconUrl'] = "https://cdn.jsdelivr.net/npm/simple-icons/icons/#{page['iconSlug']}.svg"
        end
      end

      # Explode tags space-separated string to a list if necessary.
      # Also add the category as a default tag.
      def set_tags(page)
        tags = page.data['tags']

        if tags
          tags = (tags.kind_of?(Array) ? tags : tags.split)
        else
          tags = []
        end

        tags << page.data['category']
        page.data['tags'] = tags.sort
      end

      # Set properly the column presence/label if it was overridden.
      def set_overridden_columns_label(page)
        date_column_names = [
          'releaseDateColumn', 'releaseColumn', 'discontinuedColumn',
          'activeSupportColumn', 'eolColumn', 'extendedSupportColumn'
        ]
        for date_column in date_column_names
          if page.data[date_column].is_a? String
            page.data[date_column + 'Label'] = page.data[date_column]
            page.data[date_column] = true
          end
        end
      end

      # Flag all cycles that can be hidden (see #50).
      #
      # The goal of this function is to hide only a single run of rows, at the very end, if they are
      # all unmaintained. This function presume that all cycles are ordered by their release date,
      # so a cycle can be hidden only if:
      # - it is not the first cycle,
      # - it is unmaintained (see set_is_maintained below),
      # - the previous cycle is still maintained,
      # - all next cycles are unmaintained.
      #
      # This function applies only if there are more than 6 cycles and more than 2 cycles that can
      # be hidden.
      #
      # For example, given there are 10 cycles with various state of maintainability:
      # - cycle 1 to 3 are maintained => cannot be hidden because they are maintained.
      # - cycle 4 is unmaintained => cannot be hidden because cycle 5 is maintained.
      # - cycle 5 is maintained => cannot be hidden because it is maintained.
      # - cycle 6 is unmaintained => cannot be hidden because cycle 5 is maintained.
      # - cycle 7 to 10 are unmaintained => can be hidden.
      def flag_oldest_unmaintained_releases(page)
        min_total_cycles = 6 # apply only if the number of cycles is greater than this
        min_hidden_cycles = 3 # apply only if the number of hidden cycles is greater than this (must be < min_total_cycles)

        releases = page.data['releases']
        if releases.length <= min_total_cycles
          Jekyll.logger.debug TOPIC, "Less than #{min_total_cycles} cycles on #{page.name}, will not try to hide cycles"
          return
        end

        hidden_cycles = mark_cycles_that_can_be_hidden(releases)

        if releases[0]['can_be_hidden']
          Jekyll.logger.debug TOPIC, "First cycle is hidden on #{page.name}, unhide cycle"
          releases[0].delete('can_be_hidden')
          hidden_cycles.delete(releases[0])
        end

        if hidden_cycles.length > 0 and hidden_cycles.length < min_hidden_cycles
          Jekyll.logger.debug TOPIC, "Less than #{min_hidden_cycles} hidden cycles on #{page.name}, unhide #{hidden_cycles.length} cycles"
          hidden_cycles.each { |cycle| cycle.delete('can_be_hidden') }
          hidden_cycles.clear()
        end

        Jekyll.logger.debug TOPIC, "Hide #{hidden_cycles.length} cycles on #{page.name}"
      end

      def mark_cycles_that_can_be_hidden(ordered_by_date_desc_releases)
        hidden_cycles = []
        previous_cycle = nil

        for cycle in ordered_by_date_desc_releases.reverse
          if not cycle['is_maintained']
            if previous_cycle
              previous_cycle['can_be_hidden'] = true
              hidden_cycles << previous_cycle
            end

            previous_cycle = cycle
          else
            break
          end
        end

        return hidden_cycles
      end

      def enrich_release(page, cycle)
        set_cycle_id(cycle)
        set_cycle_lts_fields(cycle)
        set_cycle_active_support_fields(cycle)
        set_cycle_extended_support_fields(cycle)
        set_cycle_eol_fields(cycle)
        set_cycle_discontinued_fields(cycle)
        set_cycle_link(page, cycle)
        set_cycle_label(page, cycle)
        add_lts_label_to_cycle_label(page, cycle) # must be called after set_cycle_lts
        compute_days_toward_now_for_all_dates(cycle)
        set_is_maintained(cycle) # must be called after compute_days_toward_now_for_all_dates
      end

      # Build the cycle id from the permalink.
      def set_cycle_id(cycle)
        cycle['id'] = cycle['releaseCycle'].tr('/', '-')
      end
      
      # Set lts to false if it has no value and explode it to is_lts (boolean) and lts_from (Date).
      # See explode_date_or_boolean_field(...) for more information.
      def set_cycle_lts_fields(cycle)
        if not cycle.has_key?('lts')
          cycle['lts'] = false
        end

        explode_date_or_boolean_field(cycle, 'lts', 'is_lts', 'lts_from')
      end

      # Explode support to is_active_support_over (boolean) and active_support_until (Date).
      # See explode_date_or_boolean_field(...) for more information.
      def set_cycle_active_support_fields(cycle)
        explode_date_or_boolean_field(cycle, 'support', 'is_active_support_over', 'active_support_until', true)
      end

      # Explode extendedSupport to is_extended_support_over (boolean) and extended_support_until (Date).
      # See explode_date_or_boolean_field(...) for more information.
      def set_cycle_extended_support_fields(cycle)
        explode_date_or_boolean_field(cycle, 'extendedSupport', 'is_extended_support_over', 'extended_support_until', true)
      end

      # Explode eol to is_eol (boolean) and eol_from (Date).
      # See explode_date_or_boolean_field(...) for more information.
      def set_cycle_eol_fields(cycle)
        explode_date_or_boolean_field(cycle, 'eol', 'is_eol', 'eol_from')
      end

      # Explode discontinued to is_discontinued (boolean) and discontinued_from (Date).
      # See explode_date_or_boolean_field(...) for more information.
      def set_cycle_discontinued_fields(cycle)
        explode_date_or_boolean_field(cycle, 'discontinued', 'is_discontinued', 'discontinued_from')
      end

      # Some product cycle fields (field_name) can be either a date or a boolean.
      # This function create two additional variables, one of boolean type (boolean_field_name) and
      # the other of Date type (date_field_name) to simplify usages in templates or Jekyll plugins.
      #
      # The invert parameter must be set according to the date nature. If it's a start date
      # (example : the eol field) set it to false, if it's an end date (example : the support field)
      # set it to true.
      def explode_date_or_boolean_field(cycle, field_name, boolean_field_name, date_field_name, invert = false)
        if not cycle.has_key?(field_name)
          return
        end

        value = cycle[field_name]
        if value.is_a?(Date)
          cycle[boolean_field_name] = (Date.today > value)
          cycle[date_field_name] = value
        else
          cycle[boolean_field_name] = invert ? !value : value
          cycle[date_field_name] = nil
        end
      end

      def set_cycle_link(page, cycle)
        if cycle.has_key?('link')
          # null link means no changelog template
          if cycle['link'] && cycle['link'].include?('__')
            cycle['link'] = render_eol_template(cycle['link'], cycle)
          end
        else
          if page['changelogTemplate']
            cycle['link'] = render_eol_template(page['changelogTemplate'], cycle)
          end
        end
      end

      def set_cycle_label(page, cycle)
        template = cycle['releaseLabel'] || page.data['releaseLabel']
        if template
          cycle['label'] = render_eol_template(template, cycle)
        else
          cycle['label'] = cycle['releaseCycle']
        end
      end

      def add_lts_label_to_cycle_label(page, cycle)
        lts_label = page.data['LTSLabel']

        if cycle['lts_from']
          if cycle['is_lts']
            cycle['label'] = "#{cycle['label']} (#{lts_label})"
          else
            cycle['label'] = "#{cycle['label']} (<span title=\"#{cycle['lts_from'].iso8601}\">Upcoming</span> #{lts_label})"
          end
        elsif cycle['is_lts']
          cycle['label'] = "#{cycle['label']} (#{lts_label})"
        end
      end

      # Compute the number of days toward now for all cycle's dates (support, eol...), and add those
      # values to the cycle's data in new fields (days_toward_support, days_toward_eol...).
      def compute_days_toward_now_for_all_dates(cycle)
        for field in ['support', 'eol', 'discontinued', 'extendedSupport']
          next if not cycle.has_key?(field)

          field_value = cycle[field] # either a date or a boolean
          new_field_name = 'days_toward_' + field

          if field_value.is_a?(Date)
            cycle[new_field_name] = days_toward_now(field_value)
          elsif ['eol', 'discontinued'].include?(field)
            cycle[new_field_name] = field_value ? -4096 : 4096 # if eol     is true, then negative days
          else
            cycle[new_field_name] = field_value ? 4096 : -4096 # if support is true, then positive days
          end
        end
      end

      # Compute whether the cycle is still maintained and add the result to the cycle's data.
      #
      # A cycle is maintained if at least one of the active support / eol / discontinued / extended
      # support dates is in the future or is true.
      #
      # This function must be executed after compute_days_toward_now_for_all_dates because it makes
      # use of the fields injected by this function.
      def set_is_maintained(cycle)
        is_maintained = false

        for daysTowardField in ['days_toward_support', 'days_toward_eol', 'days_toward_discontinued', 'days_toward_extendedSupport']
          if cycle.has_key?(daysTowardField) and cycle[daysTowardField] >= 0
            is_maintained = true
            break
          end
        end

        cycle['is_maintained'] = is_maintained
      end

      # Compute the number of days from now to the given date.
      #
      # Usage (assuming now is '2023-01-01'):
      # {{ '2023-01-10' | days_from_now }} => 9
      # {{ '2023-01-01' | days_from_now }} => 0
      # {{ '2022-12-31' | days_from_now }} => -1
      def days_toward_now(date)
        date_timestamp = date.to_time.to_i # date at midnight
        now_timestamp = Date.today.to_time.to_i # today at midnight
        return (date_timestamp - now_timestamp) / (60 * 60 * 24)
      end

      def render_eol_template(template, cycle)
        link = template.gsub('__RELEASE_CYCLE__', cycle['releaseCycle'] || '')
        link.gsub!('__CODENAME__', cycle['codename'] || '')
        link.gsub!('__LATEST__', cycle['latest'] || '')
        link.gsub!('__LATEST_RELEASE_DATE__', cycle['latestReleaseDate'] ? cycle['latestReleaseDate'].iso8601 : '')
        return Liquid::Template.parse(link).render(@context)
      end
    end
  end
end

Jekyll::Hooks.register [:pages], :post_init, priority: Jekyll::Hooks::PRIORITY_MAP[:normal] do |page|
  Jekyll::ProductDataEnricher.enrich(page) if Jekyll::ProductDataEnricher.is_product?(page)
end
