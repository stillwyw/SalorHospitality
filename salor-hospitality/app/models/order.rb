# coding: UTF-8

# Copyright (c) 2012 Red (E) Tools Ltd.
#
# Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

class Order < ActiveRecord::Base
  include ActionView::Helpers::NumberHelper
  include Scope
  belongs_to :company
  belongs_to :vendor
  belongs_to :settlement
  belongs_to :table
  belongs_to :user
  belongs_to :cost_center
  belongs_to :customer
  belongs_to :tax
  belongs_to :booking
  has_many :items, :dependent => :destroy
  has_many :payment_method_items
  has_many :tax_items
  has_many :option_items
  has_many :receipts
  has_one :order

  serialize :taxes

  #validates_presence_of :user_id

  accepts_nested_attributes_for :items, :allow_destroy => true #, :reject_if => proc { |attrs| attrs['count'] == '0' || ( attrs['article_id'] == '' && attrs['quantity_id'] == '') }
  
  def customer_name
    if self.customer then
      return self.customer.full_name(true)
    end
    return ""
  end

  def customer_name=(name)
    last,first = name.split(' ')
    return if not last or not first
    c = Customer.where(:first_name => first.strip, :last_name => last.strip).first
#     if not c then
#       c = Customer.create(:first_name => first.strip,:last_name => last.strip, :vendor_id => self.vendor_id, :company_id => self.company_id)
#       self.vendor.update_cache if self.vendor
#     end
    self.customer = c
    self.save
  end

  def set_nr
    if self.nr.nil?
      self.update_attribute :nr, self.vendor.get_unique_model_number('order')
    end
  end

  def self.create_from_params(params, vendor, user, customer)
    order = Order.new params[:model]
    order.user = user unless order.user
    order.customer = customer if customer
    order.vendor = vendor
    order.company = vendor.company
    params[:items].to_a.each do |item_params|
      order.create_new_item(item_params, user)
    end
    raise "Order could not be saved." unless order.save
    #new_user = (params[:items] or self.user.nil?) ? user : nil # only change user if items were changed.
    order.update_associations(customer)
    order.regroup
    order.calculate_totals
    order.update_payment_method_items(params)
    hidden_by = user ? user.id : -12
    order.hide(hidden_by) if order.hidden or not order.items.existing.any?
    order.set_nr
    order.table.update_color
    return order
  end

  def update_from_params(params, user, customer)
    self.update_attributes params[:model]
    params[:items].to_a.each do |item_params|
      item_id = item_params[1][:id]
      if item_id
        self.update_item(item_id, item_params, user)
      else
        self.create_new_item(item_params, user)
      end
    end
    self.user = user if self.user.nil? or (params[:items] and params[:model][:user_id].nil?)
    self.save
    self.update_associations(customer)
    self.regroup
    self.calculate_totals
    self.update_payment_method_items(params)
    hidden_by = user ? user.id : -12
    self.hide(hidden_by) if self.hidden or not self.items.existing.any?
    self.table.update_color
  end
  
  def create_new_item(p, user)
    i = Item.new(p[1])
    i.order = self
    i.vendor = vendor
    i.company = vendor.company
    if p[1][:p]
      i.price_changed = true
      i.price_changed_by = user.id
    end
    result = i.save
    if result == false
      message = "Could not save item in Order.create_new_item. Item: #{ i.inspect }, Errors: #{ i.errors.inspect }, Params: #{p.inspect}."
      if self.vendor.enable_technician_emails == true and self.vendor.technician_email
        UserMailer.technician_message(self.vendor, "Could not save item in Order.create_new_item", message).deliver
      else
        ActiveRecord::Base.logger.info "[TECHNICIAN] #{ message }"
      end
    end
    i.create_option_items_from_ids p[1][:i]
    i.option_items.each { |oi| oi.calculate_totals }
    if i.article
      i.calculate_totals
    else
      message = "No article associated with item in Order.create_new_item. Item: #{ i.inspect }, Params: #{p.inspect}."
      if self.vendor.enable_technician_emails == true and self.vendor.technician_email
        UserMailer.technician_message(self.vendor, "No article associated with item in Order.create_new_item.", message).deliver
      else
        ActiveRecord::Base.logger.info "[TECHNICIAN] #{ message }"
      end
    end
    i.hide(self.user_id) if i.hidden
  end
  
  def update_item(id, p, user)
    p[1].delete(:id)
    i = Item.find_by_id(id)
    result = i.update_attributes(p[1])
    if p[1][:p]
      i.update_attribute :price_changed, true
      i.update_attribute :price_changed_by, user.id
    end
    if result == false
      message = "Could not update item in Order.update_item. Item: #{ i.inspect }, Errors: #{ i.errors.inspect }, Params: #{p.inspect}."
      if self.vendor.enable_technician_emails == true and self.vendor.technician_email
        UserMailer.technician_message(self.vendor, "Could not update item in Order.update_item", message).deliver
      else
        ActiveRecord::Base.logger.info "[TECHNICIAN] #{ message }"
      end
    end
    i.create_option_items_from_ids p[1][:i]
    i.option_items.each { |oi| oi.calculate_totals }
    if i.article
      i.calculate_totals
    else
      message = "No article associated with item in Order.update_item. Item: #{ i.inspect }, Params: #{p.inspect}."
      if self.vendor.enable_technician_emails == true and self.vendor.technician_email
        UserMailer.technician_message(self.vendor, "No article associated with item in Order.update_item.", message).deliver
      else
        ActiveRecord::Base.logger.info "[TECHNICIAN] #{ message }"
      end
    end
    i.hide(user.id) if i.hidden
  end
  
  def update_payment_method_items(params)
    #ActiveRecord::Base.logger.info "XXXX #{ self.user_id }"
    # create payment method items only when 1) there are some, 2) cost center does not forbid creating payment method items
    if params['payment_method_items'] and self.vendor.payment_methods.existing.any? and ( self.cost_center.nil? or (self.cost_center and self.cost_center.no_payment_methods == false))
      self.payment_method_items.update_all(:hidden => true, :hidden_by => -7, :hidden_at => Time.now) # we don't re-use previously created payment method items
      params['payment_method_items'][params['id']].to_a.each do |pm|
        # only create payment method items that are not zero and that have not been removed from the UI
        if pm[1]['amount'].to_f > 0 and pm[1]['_delete'].to_s == 'false'
          payment_method = self.vendor.payment_methods.existing.find_by_id(pm[1]['id'])
          PaymentMethodItem.create :payment_method_id => pm[1]['id'], :amount => pm[1]['amount'], :order_id => self.id, :vendor_id => self.vendor_id, :company_id => self.company_id, :cash => payment_method.cash, :user_id => self.user_id
        end
      end
    end
  end

  def update_associations(customer=nil)
    self.cost_center = self.vendor.cost_centers.existing.first unless self.cost_center
    self.save
    
    self.items.update_all :cost_center_id => self.cost_center
    self.tax_items.update_all :cost_center_id => self.cost_center, :user_id => self.user_id
    self.payment_method_items.update_all :cost_center_id => self.cost_center_id, :user_id => self.user_id
    
    table = self.table
    if customer.nil?
      # when a waiter re-submits an order, @current_customer is nil. the waiter confirms all notifications by virtue of re-submitting the order. The table will no longer be associated with a customer
      table.confirmations_pending = false
      table.request_finish = false
      table.request_waiter = false
      table.request_order = false
    else
      table.confirmations_pending = self.items.existing.where("confirmation_count IS NULL OR count > confirmation_count").any? # this boolean flag will cause the table to pulsate on the tables screen
    end
    table.save
    
    # Set item notifications
    remote_orders = self.vendor.remote_orders
    self.items.existing.each do |i|
      if customer.nil?
        # waiter confirms
        confirmation_count = i.count
      else
        confirmation_count = i.confirmation_count # do nothing
      end
      i.user_id = self.user_id
      i.vendor_id = self.vendor_id
      i.company_id = self.company_id
      i.preparation_user_id = i.category.preparation_user_id
      i.delivery_user_id = self.user_id
      i.confirmation_count = confirmation_count
      i.save
    end
  end

  def calculate_totals
    self.sum = self.items.existing.where(:refunded => nil).sum(:sum).round(2)
    self.refund_sum = self.items.existing.where(:refunded => true).sum(:refund_sum).round(2)
    self.tax_sum = self.items.existing.where(:refunded => nil).sum(:tax_sum).round(2)
    self.calculate_taxes
    self.save
  end
  
  def calculate_taxes
    self.taxes = {}
    self.items.existing.where(:refunded => nil).each do |item|
      item.taxes.each do |k,v|
        if self.taxes.has_key? k
          self.taxes[k][:t] += v[:t]
          self.taxes[k][:g] += v[:g]
          self.taxes[k][:n] += v[:n]
          self.taxes[k][:t] =  self.taxes[k][:t].round(2)
          self.taxes[k][:g] =  self.taxes[k][:g].round(2)
          self.taxes[k][:n] =  self.taxes[k][:n].round(2)
        else
          self.taxes[k] = v
        end
      end
    end
    self.save
  end

  def hide(by_user_id)
    self.vendor.unused_order_numbers << self.nr
    self.vendor.save
    self.nr = nil
    self.hidden = true
    self.hidden_by = by_user_id
    self.save
    self.unlink
    self.option_items.update_all :hidden => true, :hidden_by => by_user_id, :hidden_at => Time.now
    self.tax_items.update_all :hidden => true, :hidden_by => by_user_id, :hidden_at => Time.now
    self.items.update_all :hidden => true, :hidden_by => by_user_id, :hidden_at => Time.now
    self.payment_method_items.update_all :hidden => true, :hidden_by => by_user_id, :hidden_at => Time.now
    
    # detach customer from table
    if self.table.customer
      customer = self.table.customer
      unless customer.logged_in == true
        customer.table = nil
        customer.save
      end
    end
  end

  def unlink
    split_order = self.order
    if split_order
      split_order.items.update_all :item_id => nil
      split_order.order = nil
      split_order.save
    end
    self.order = nil
    self.save
    self.items.update_all :item_id => nil
  end

  def move(target_table_id)
    ActiveRecord::Base.logger.info "order.rb move: called on self #{ self.inspect }"
    return if self.table_id == target_table_id.to_i
    target_order = Order.existing.where(:table_id => target_table_id, :finished => false).first
    ActiveRecord::Base.logger.info "order.rb move: target_order is #{ target_order.inspect }"
    ActiveRecord::Base.logger.info "order.rb move: unlinking self"
    self.unlink
    ActiveRecord::Base.logger.info "order.rb move: reloading self"
    self.reload
    origin_table = self.table
    ActiveRecord::Base.logger.info "order.rb move: origin_table = #{ origin_table.inspect }"
    target_table = Table.find_by_id target_table_id
    ActiveRecord::Base.logger.info "order.rb move: target_table = #{ target_table.inspect }"

    if target_order
      ActiveRecord::Base.logger.info "order.rb move: updating item/option_item/tax_item ids = #{ self.items.collect{ |i| i.id }.inspect } with order_id #{ target_order.id }"
      self.items.update_all :order_id => target_order.id
      self.option_items.update_all :order_id => target_order.id
      self.tax_items.update_all :order_id => target_order.id
      self.reload
      self.calculate_totals
      self.hide(-1)
      target_order.regroup
      #target_order.items.existing.each { |i| i.calculate_totals } # this is already called in .regroup
      target_order.calculate_totals
    else
      ActiveRecord::Base.logger.info "order.rb move: setting target_table_id #{ target_table_id } for self"
      self.table_id = target_table_id
      result = self.save
      if result != true
        ActiveRecord::Base.logger.info "order.rb move: ERROR: could not save self because #{ self.errors.messages }"
      end
    end
    origin_table.update_color
    target_table.update_color
  end

  def regroup
    items = self.items.existing
    n = items.size - 1
    0.upto(n-1) do |i|
      (i+1).upto(n) do |j|
        if (items[i].article_id  == items[j].article_id    and
            items[i].quantity_id == items[j].quantity_id   and
            items[i].option_items.existing.collect{|oi| oi.option.id}.uniq.sort == items[j].option_items.existing.collect{|oi| oi.option.id}.uniq  and
            items[i].price       == items[j].price         and
            items[i].comment     == items[j].comment       and
            items[i].scribe      == items[j].scribe        and
            items[i].refunded    == nil                    and
            items[j].refunded    == nil                    and
            not items[i].destroyed?
            )
          items[i].count += items[j].count
          items[i].printed_count += items[j].printed_count
          items[i].save # this is needed for the next step
          items[i].option_items.each{|oi| oi.calculate_totals }
          items[i].calculate_totals
          items[j].hide(-2)
        end
      end
    end
  end

  def finish(user=nil)
    self.update_attribute :finished, true # this happens intentionally as soon as possible, since it will be checked in the Item.split_items function.
    self.finished_at = Time.now
    self.user = user if user
    Item.connection.execute("UPDATE items SET confirmation_count = count, preparation_count = count, delivery_count = count WHERE vendor_id=#{self.vendor_id} AND  company_id=#{self.company_id} AND order_id=#{self.id};")
    self.save
    self.unlink
    self.set_nr # in theory not neccessary, but just to make sure
    self.table.update_color
    
    # detach customer from this table
    customer = self.customer
    if customer
      customer.table = nil
      customer.save
    end
    
    self.items.existing.each do |i|
      i.option_items.existing.each do |oi|
        oi.hide(-10) if oi.price == 0.0
      end
    end
    self.regroup
  end

  def pay(user=nil)
    return if self.hidden # this happens when called from application_controller, 'pay_and_no_print' when splitting an item and order is deleted.
    self.finish(user)
    # create a cash payment method item if none was set in the UI, and if the cost center does not prohibit this
    unless self.payment_method_items.existing.any? or (self.cost_center and self.cost_center.no_payment_methods == true)
      cash_payment_methods = self.vendor.payment_methods.existing.where(:cash => true)
      cash_payment_method = cash_payment_methods.first
      if cash_payment_method
        PaymentMethodItem.create :company_id => self.company_id, :vendor_id => self.vendor_id, :order_id => self.id, :payment_method_id => cash_payment_method.id , :cash => true, :amount => self.sum, :user_id => self.user_id
      end
    end
    
    payment_method_sum = self.payment_method_items.existing.sum(:amount) # refunded is never true at this point, since an order must be first finished/paid before it can be refunded
    
    # create a change payment method item
    unless self.payment_method_items.existing.where(:change => true).any? or (self.cost_center and self.cost_center.no_payment_methods == true)
      change_payment_methods = self.vendor.payment_methods.where(:change => true)
      if change_payment_methods.any?
        PaymentMethodItem.create :company_id => self.company_id, :vendor_id => self.vendor_id, :order_id => self.id, :change => true, :amount => (payment_method_sum - self.sum).round(2), :payment_method_id => change_payment_methods.first.id, :user_id => self.user_id
      end
    end
    
    self.payment_method_items.update_all :cost_center_id => self.cost_center_id
    
    self.change_given = (payment_method_sum - self.sum).round(2)
    self.paid = true
    self.paid_at = Time.now
    self.save
    self.table.update_color
  end
  
  def reactivate(user)
    # try to restore the original table
    used_table = self.vendor.tables.existing.where(:id => self.table_id, :active_user_id => nil).first
    if used_table.nil?
      # if original table is occupied, use the first empty table
      used_table = self.vendor.tables.existing.where(:active_user_id => nil).first
    end
    return nil unless used_table
    self.table_id = used_table.id
    self.finished = false
    self.finished_at = nil
    self.reactivated  = true
    self.reactivated_by = user.id
    self.reactivated_at = Time.now
    self.user_id = user.id
    self.paid = false
    self.change_given = nil
    self.taxes = {}
    self.paid_at = nil
    self.save
    self.payment_method_items.existing.update_all :hidden => true, :hidden_by => -5, :hidden_at => Time.now
    used_table.update_color
    return used_table
  end

  def print(what, vendor_printer=nil, options={})
    # The print location of a receipt is always chosen from the UI and controlled here by the parameter vendor_printer. The print location of tickets are only determined by the Category.vendor_printer_id setting.
    if what.include? 'tickets'
      vendor_printers = self.vendor.vendor_printers.existing
      print_engine = Escper::Printer.new(self.company.mode, vendor_printers, File.join(SalorHospitality::Application::SH_DEBIAN_SITEID, self.vendor.hash_id))
    else
      print_engine = Escper::Printer.new(self.company.mode, vendor_printer, File.join(SalorHospitality::Application::SH_DEBIAN_SITEID, self.vendor.hash_id))
    end

    print_engine.open

    # print
    if what.include? 'tickets'
      unless self.vendor.categories.existing.all? {|c| c.vendor_printer_id == nil}
        vendor_printers.each do |p|
          contents = self.escpos_tickets(p.id)
          unless contents[:text].empty?
            bytes_written, content_sent = print_engine.print(p.id, contents[:text], contents[:raw_insertations])
            
            # Push notification
            if SalorHospitality.tailor
              printerstring = sprintf("%04i", p.id)
              begin
                SalorHospitality.tailor.puts "PRINTEVENT|#{self.vendor.hash_id}|printer#{printerstring}"
              rescue Exception => e
                ActiveRecord::Base.logger.info "[TAILOR] Exception #{ e } during printing."
              end
            end
            
            bytes_sent = content_sent.length
            Receipt.create(:vendor_id => self.vendor_id, :company_id => self.company_id, :user_id => self.user_id, :vendor_printer_id => p.id, :order_id => self.id, :order_nr => self.nr, :content => contents[:text], :bytes_sent => bytes_sent, :bytes_written => bytes_written)
          end
        end
      end
    end
    
    if what.include? 'receipt'
      if vendor_printer
        contents = self.escpos_receipt(options)
        pulse = "\x1B\x70\x00\x99\x99\x0C"
        contents[:text] = pulse + contents[:text] if vendor_printer.pulse_receipt == true and self.printed.nil?
        bytes_written, content_sent = print_engine.print(vendor_printer.id, contents[:text], contents[:raw_insertations])
        
        # Push notification
        if SalorHospitality.tailor
          printerstring = sprintf("%04i", vendor_printer.id)
          begin
            SalorHospitality.tailor.puts "PRINTEVENT|#{self.vendor.hash_id}|printer#{printerstring}"
          rescue Exception => e
            ActiveRecord::Base.logger.info "[TAILOR] Exception #{ e } during printing."
          end
        end
        
        bytes_sent = content_sent.length
        Receipt.create(:vendor_id => self.vendor_id, :company_id => self.company_id, :user_id => self.user_id, :vendor_printer_id => vendor_printer.id, :order_id => self.id, :order_nr => self.nr, :content => contents[:text], :bytes_sent => bytes_sent, :bytes_written => bytes_written)
        self.update_attribute :printed, true
      end
    end
    
    if what.include? 'interim_receipt'
      # this is currently not implemented and never called.
      if vendor_printer
        contents = self.escpos_interim_receipt
        bytes_written, content_sent = print_engine.print(vendor_printer.id, contents)
        
        # Push notification
        if SalorHospitality.tailor
          printerstring = sprintf("%04i", vendor_printer.id)
          begin
            SalorHospitality.tailor.puts "PRINTEVENT|#{self.vendor.hash_id}|printer#{printerstring}"
          rescue Exception => e
            ActiveRecord::Base.logger.info "[TAILOR] Exception #{ e } during printing."
          end
        end
        
        bytes_sent = content_sent.length
        Receipt.create(:vendor_id => self.vendor_id, :company_id => self.company_id, :user_id => self.user_id, :vendor_printer_id => vendor_printer.id, :order_id => self.id, :order_nr => self.nr, :content => contents, :bytes_sent => bytes_sent, :bytes_written => bytes_written)
        self.update_attribute :printed_interim, true
      end
    end
    print_engine.close
  end

  def escpos_tickets(printer_id)
    vendor = self.vendor
    if vendor.ticket_wide_font
      header_format_time_order = "%-14.14s #%5i\n"
      header_format_user_table = "%-12.12s %8s\n"
      header_note_format = "%20.20s\n"
      article_format = "%i %-18.18s\n"
      quantity_format  = " > %-18.18s\n"
      comment_format   = " ! %-18.18s\n"
      option_format    = " * %-18.18s\n"
      width = 21
      item_separator_format = "\xC4" * (width - 11) + " %10.10s\n"
    else
      header_format_time_order = "%-35.35s #%5i\n"
      header_format_user_table = "%-33.33s %8s\n"
      header_note_format = "%42.42s\n"
      article_format     = "%2i %-39.39s\n"
      quantity_format    = "   > %-37.37s\n"
      comment_format     = "   ! %-37.37s\n"
      option_format      = "   * %-37.37s\n"
      width = 42
      item_separator_format = "\xC4" * (width - 11) + " %10.10s\n"
    end

    if vendor.ticket_wide_font and not vendor.ticket_tall_font
      fontsize = 0x20
    elsif not vendor.ticket_wide_font and vendor.ticket_tall_font
      fontsize = 0x10
    elsif vendor.ticket_wide_font and vendor.ticket_tall_font
      fontsize = 0x30
    else
      fontsize = 0x00
    end
    fontstyle = fontsize | 0x08

    init =
    "\e@" +  # Initialize Printer
    "\e!" +
    fontstyle.chr +
    "\n\n\n\n\n"

    cut =
    "\n\n\n\n\n\n" +
    "\x1D\x56\x00"
    
    pulse =
    "\x1B\x70\x00\x99\x99\x0C"

    header = ''
    
    nr = self.nr ? self.nr : 0 # failsafe for the sprintf command below
    if vendor.ticket_display_time_order
      header += header_format_time_order % [I18n.l(Time.now + vendor.time_offset.hours, :format => :time_short), (vendor.use_order_numbers ? nr : 0)]
    end

    header += header_format_user_table % [self.user.login, self.table.name]

    header += header_note_format % [self.note] if self.note and not self.note.empty?
    header += "\xDF" * width + "\n"

    separate_receipt_contents = []
    normal_receipt_content = ''
      
    selected_categories = printer_id.nil? ? self.vendor.categories.existing.active.positioned : self.vendor.categories.existing.active.positioned.where(:vendor_printer_id => printer_id)
    
    raw_insertations = {}
    selected_categories.each do |c|
      items = self.items.existing.where("count > printed_count AND category_id = #{ c.id }")
      catstring = ''
      items.each do |i|
        next if i.option_items.find_all_by_no_ticket(true).any?
        itemstring = ''
        itemstring += article_format % [ i.count - i.printed_count, i.article.name]
        itemstring += quantity_format % ["#{i.quantity.prefix} #{i.quantity.postfix}"] if i.quantity
        itemstring += comment_format % [i.comment] unless i.comment.empty?
        i.option_items.each do |oi|
          itemstring += option_format % [oi.name]
        end
        
        if i.scribe_escpos
          raw_insertations.merge! :"scribe#{i.id}" => i.scribe_escpos.force_encoding('ASCII-8BIT')
          markup = "{::escper}scribe#{i.id}{:/}"
          itemstring += markup
        end

        if vendor.ticket_item_separator
          item_separator_values = number_with_precision((i.price + i.options_price) * (i.count - i.printed_count), :locale => vendor.region)
          itemstring += item_separator_format % item_separator_values
        end
        
        if i.option_items.find_all_by_separate_ticket(true).any?
          separate_receipt_contents << itemstring
        else
          catstring += itemstring
        end
        i.update_attribute :printed_count, i.count
      end

      unless items.size.zero?
        if c.separate_print == true
          separate_receipt_contents << catstring
        else
          normal_receipt_content += catstring
        end
      end
    end

    output = init
    separate_receipt_contents.each do |content|
      unless content.empty?
        output +=
            header +
            content +
            cut
      end
    end
    
    unless normal_receipt_content.empty?
      output +=
          header +
          normal_receipt_content +
          cut
    end
       
    if output == init
      # print nothing
      return {:text => '', :raw_insertations => {}}
    else
      vendor_printer = self.vendor.vendor_printers.find_by_id(printer_id)
      output += pulse if vendor_printer.pulse_tickets == true
      return {:text => output, :raw_insertations => raw_insertations }
    end
  end


  def escpos_receipt(options={})
    if self.vendor.country == 'vi'
      # very large integers
      header3_format = "   %-13.13s %10.10s %5.5s"
      options_format = "%2s %13.13s %10.10s %3u %10.10s\n"
      items_format = "%2s %13.13s %10.10s %3u %10.10s\n"
      sum_format = "%s:   %s %s"
      refundsum_format = "\n%s:   %s %s"
      tax_header_format = "         %10.10s %10.10s %10.10s\n"
      tax_format = "%s:  %2i%%  %10.10s  %10.10s  %10.10s\n"
      payment_method_format = "%22.22s: %10.10s\n"
    else
      header3_format = "   %-17.17s %8.8s   %4.4s"
      options_format = "%2s %17.17s %8.8s %3u %8.8s\n"
      items_format = "%2s %17.17s %8.8s %3u %8.8s\n"
      sum_format = "%s:   %s %s"
      refundsum_format = "\n%s:   %s %s"
      tax_header_format = "      %8.8s %8.8s %8.8s\n"
      tax_format = "%s: %2i%% %8.8s %8.8s %8.8s\n"
      payment_method_format = "%22.22s: %8.8s\n"
    end
    
    vendor = self.vendor
    
    friendly_unit = I18n.t('number.currency.format.friendly_unit', :locale => SalorHospitality::Application::COUNTRIES_REGIONS[vendor.country])

    vendorname =
    "\e@"     +  # Initialize Printer
    "\e!\x38" +  # doube tall, double wide, bold
    vendor.name + "\n"

    header1 = ''
    header1 +=
    "\e!\x01" +  # Font B
    "\ea\x01" +  # center
    "\n" + vendor.receipt_header_blurb + "\n" if vendor.receipt_header_blurb
    
    lines = ''
    if options[:with_customer_lines] == true
      lines += "\e!\x00"  # Font A
      4.times do |i|
        lines += "\xc4" * 42 + "\n\n"
      end
    end
    
    customer_data = ''
    if self.customer
      cst = self.customer
      cst_values = [
        cst.company_name,
        cst.first_name,
        cst.last_name,
        cst.address,
        cst.postalcode,
        cst.city,
        cst.tax_info,
        cst.telephone
      ]
      cst_format = "\n%s\n%s %s\n%s\n%s %s\n%s\n%s\n\n"
      customer_data += cst_format % cst_values
    end
    
    note_line = ''
    unless self.note.blank?
      note_line = "\n\n%s\n\n" % self.note
    end
    
    header2 = ''
    header2 +=
    "\ea\x00" +  # align left
    "\e!\x01" +  # Font B
    I18n.t('served_by_X_on_table_Y', :waiter => self.user.title, :table => self.table.name) + "\n"

    header2 += I18n.t('invoice_numer_X_at_time', :number => self.nr, :datetime => I18n.l(self.finished_at + vendor.time_offset.hours, :format => :long)) if vendor.use_order_numbers

    header3 =
        "\n\n" +
        "\e!\x00" # Font A
    
    header3_values = [
      I18n.t('activerecord.models.article.one'),
      I18n.t('various.unit_price_abbreviation'),
      I18n.t('various.quantity_abbreviation'),
      I18n.t('various.total_price_abbreviation')
    ]
      
    header3 += header3_format % header3_values
    header3 +=
        "\n" +
        "\xc4" * 42 +
        "\n"

    list_of_items = ''
    self.items.existing.order(:position_category).each do |item|
      next if item.count == 0
      list_of_options = ''
      item.option_items.each do |oi|
        next if oi.price == 0
        options_values = [
          item.taxes.collect{|k,v| v[:l]}[0..1].join(''),
          "#{ I18n.t(:refund) + ' ' if item.refunded}#{ oi.name }",
          oi.price,
          item.count,
          item.refunded ? 0 : number_with_precision(oi.price * item.count, :locale => vendor.get_region)
        ]
        list_of_options += options_format % options_values
      end

      label = item.quantity ? "#{ I18n.t(:refund) + ' ' if item.refunded }#{ item.quantity.prefix } #{ item.quantity.article.name }#{ ' ' unless item.quantity.postfix.empty? }#{ item.quantity.postfix }" : "#{ I18n.t(:refund) + ' ' if item.refunded }#{ item.article.name }"

      item_sum = item.refunded ? 0 : item.price * item.count
      items_values = [
        item.taxes.collect{|k,v| v[:l]}[0..1].join(''),
        label,
        number_with_precision(item.price, :locale => vendor.get_region),
        item.count,
        number_with_precision(item_sum, :locale => vendor.get_region)
      ]
      list_of_items += items_format % items_values
      list_of_items += list_of_options
    end

    sum_style =
        " " * 30 +
        "\xcd" * 12 +
        "\r\n" +
        "\e!\x18" + # double tall, bold
        "\ea\x02"   # align right

    sum_values = [
      I18n.t(:sum).upcase,
      friendly_unit,
      number_with_precision(self.sum, :locale => vendor.get_region)
    ]
    sum = sum_format % sum_values

    if self.refund_sum.zero?
      refund = ''
    else
      refundsum_values = [
        I18n.t(:refund),
        friendly_unit,
        number_with_precision(self.refund_sum, :locale => vendor.get_region)
      ]
      refund = refundsum_format % refundsum_values
    end

    tax_style =
        "\n\n" +
        "\ea\x01" +  # align center
        "\e!\x01"    # Font B

    tax_header_values = [
      I18n.t(:net),
      I18n.t('various.tax'),
      I18n.t(:gross)
    ]
    tax_header = tax_header_format % tax_header_values

    list_of_taxes = ''
    self.taxes.each do |k,v|
      tax_values = [
        v[:l],
        v[:p],
        number_with_precision(v[:n], :locale => vendor.get_region),
        number_with_precision(v[:t], :locale => vendor.get_region),
        number_with_precision(v[:g], :locale => vendor.get_region)
      ]  
      list_of_taxes += tax_format % tax_values
    end
    
    list_of_payment_methods = "\n"
    if self.user.role.permissions.include? 'manage_payment_methods'
      self.payment_method_items.each do |pm|
        name = pm.refunded ? "#{ I18n.t(:refund) } #{ pm.refund_item.article.name } #{pm.payment_method.name}" : pm.payment_method.name
        payment_method_values = [
          name,
          number_with_precision(pm.amount, :locale => vendor.get_region)
        ]
        list_of_payment_methods += payment_method_format % payment_method_values unless pm.amount.zero?
      end
    end

    footer = ''
    if vendor.receipt_footer_blurb
      footer =
          "\ea\x01" +  # align center
          "\e!\x00" + # font A
          "\n" +
          vendor.receipt_footer_blurb +
          "\n"
    end

    duplicate = self.printed ? " *** DUPLICATE/COPY/REPRINT *** " : ''
    
    raw_insertations = {}
    if vendor.rlogo_header
      headerlogo = "{::escper}headerlogo{:/}"
      raw_insertations.merge! :headerlogo => vendor.rlogo_header
    else
      headerlogo = vendorname
    end
    
    if vendor.rlogo_footer
      footerlogo = "{::escper}footerlogo{:/}"
      raw_insertations.merge! :footerlogo => vendor.rlogo_footer
    else
      footerlogo = ''
    end
    
    paper_cut = "\x1DV\x00\x0C"

    output_text =
        "\e@" +     # initialize
        "\ea\x01" + # align center
        headerlogo +
        header1 +
        lines +
        customer_data +
        note_line +
        header2 +
        header3 +
        list_of_items +
        sum_style +
        sum +
        refund +
        tax_style +
        tax_header +
        list_of_taxes +
        list_of_payment_methods +
        footer +
        duplicate +
        "\n" +
        footerlogo +
        "\n\n\n\n\n\n" +
        paper_cut
    
    return { :text => output_text, :raw_insertations => raw_insertations }
  end
  
  def escpos_interim_receipt
    vendor = self.vendor
    
    friendly_unit = I18n.t('number.currency.format.friendly_unit', :locale => SalorHospitality::Application::COUNTRIES_REGIONS[vendor.country])

    header2 = "\n\n" +
    "\e!\x00" +  # Font A
    "                 #{I18n.t('activerecord.models.article.one')}   #{I18n.t('various.unit_price_abbreviation')}   #{I18n.t('various.quantity_abbreviation')}    #{I18n.t('various.total_price_abbreviation')}\n" +
    "\xc4" * 42 + "\n"

    list_of_items = ''
    self.items.existing.order(:position_category).each do |item|
      next if item.count == 0
      list_of_options = ''
      item.option_items.each do |oi|
        next if oi.price == 0
        list_of_options += "%2s %21.21s %6.2f %3u %6.2f\n" % [item.taxes.collect{|k,v| v[:l]}[0..1].join(''), "#{ I18n.t(:refund) + ' ' if item.refunded}#{ oi.name }", oi.price, item.count, item.refunded ? 0 : (oi.price * item.count)]
      end

      label = item.quantity ? "#{ I18n.t(:refund) + ' ' if item.refunded }#{ item.quantity.prefix } #{ item.quantity.article.name }#{ ' ' unless item.quantity.postfix.empty? }#{ item.quantity.postfix }" : "#{ I18n.t(:refund) + ' ' if item.refunded }#{ item.article.name }"

      item_sum = item.refunded ? 0 : item.price * item.count
      list_of_items += "%2s %21.21s %6.2f %3u %6.2f\n" % [item.taxes.collect{|k,v| v[:l]}[0..1].join(''), label, item.price, item.count, item_sum]
      list_of_items += list_of_options
    end

    sum_format =
    "\e!\x18" + # double tall, bold
    "\ea\x02"   # align right

    sum = "#{I18n.t(:sum).upcase}:   #{friendly_unit} %.2f" % self.sum

    output_text =
        "\e@" +     # initialize
        header2 +
        list_of_items +
        sum_format +
        sum +
        "\n\n\n\n\n\n\n\n\n\n\n" +
        "\x1DV\x00\x0C" # paper cut
    return output_text
  end

  def items_to_json
    a = {}
    self.items.existing.positioned.reverse.each do |i|
      
      if i.quantity_id
        d = "q#{i.quantity_id}"
      else
        d = "a#{i.article_id}"
      end

      parent_price = i.quantity ? i.quantity.price : i.article.price
      
      if i.option_items.any? or not i.comment.empty? or i.scribe or i.price != parent_price or not a[d].nil?
        # item has been modified in a unique way, so we output a unique key
        d = "i#{i.id}"
      end
      
      options = {}
      optioncount = 0
      i.option_items.existing.each do |oi|
        optioncount += 1
        options.merge! optioncount => {
          :id => oi.option_id,
          :n => oi.name,
          :p => oi.price
        }
      end
      if i.quantity_id
        a.merge! d => {
          :id => i.id,
          :ci => i.category_id,
          :ai => i.article_id,
          :qi => i.quantity_id,
          :d => d,
          :c => i.count,
          :sc => i.count,
          :p => i.price,
          :o => i.comment,
          :t => options,
          :i => [],
          :pre => i.quantity.prefix,
          :post => i.quantity.postfix,
          :n => i.article.name,
          :s => i.position,
          :h => !i.scribe.nil?
        }
      else
        a.merge! d => {
          :id => i.id,
          :ci => i.category_id,
          :ai => i.article_id,
          :d => d,
          :c => i.count,
          :sc => i.count,
          :p => i.price,
          :o => i.comment,
          :t => options,
          :i => [],
          :pre => '',
          :post => '',
          :n => i.article.name,
          :s => i.position,
          :h => !i.scribe.nil?
        }
      end
    end
    return a.to_json
  end
  
  def invoice_items_to_json
    # to be implemented
  end
  
  def check
    messages = []
    tests = []
    self.items.each do |i|
      messages << i.check
    end
    
    order_hash_tax_sum = 0
    self.taxes.each do |k,v|
      order_hash_tax_sum += v[:t]
    end
    tests[1] = order_hash_tax_sum.round(2) == self.tax_sum.round(2)

    unless self.hidden
      tests[2] = self.tax_sum.round(2) == self.tax_items.where(:refunded => nil).existing.sum(:tax).round(2)
      tests[3] = self.items.where(:refunded => nil).existing.sum(:sum).round(2) == self.sum.round(2)
      tests[4] = self.items.where(:refunded => nil).existing.sum(:tax_sum).round(2) == self.tax_sum.round(2)
      
      # order sum must match the PAYMENT METHOD ITEM sum
      if self.paid and (self.cost_center.nil? or self.cost_center.no_payment_methods != true) and self.vendor.payment_method_items.existing.any?
        tests[5] = self.sum.round(2) == (self.payment_method_items.existing.where(:refunded => nil, :change => false).sum(:amount) - self.payment_method_items.existing.where(:refunded => nil, :change => true).sum(:amount) - self.payment_method_items.existing.where(:refunded => true).sum(:amount)).round(2)
      end
      
      if self.paid and self.cost_center and self.cost_center.no_payment_methods == true
        tests[6] = self.payment_method_items.any? == false
      end
    end

    # cost_center_id may only be nil if there are no CostCenters defined
    tests[8] = self.cost_center_id or (self.cost_center_id.nil? and not self.vendor.cost_centers.existing.any?)
    
    # all associations must have the same COST CENTER
    tests[12] = self.items.collect{ |i| i.cost_center_id == self.cost_center_id }.all?
    tests[13] = self.tax_items.collect{ |i| i.cost_center_id == self.cost_center_id }.all?
    tests[14] = self.payment_method_items.collect{ |i| i.cost_center_id == self.cost_center_id }.all?
    
    # all associations must have the same SETTLEMENT
    tests[15] = self.items.collect{ |i| i.settlement_id == self.settlement_id }.all?
    tests[16] = self.tax_items.collect{ |i| i.settlement_id == self.settlement_id }.all?
    tests[17] = self.payment_method_items.collect{ |i| i.settlement_id == self.settlement_id }.all?
    
    # all associations must be HIDDEN
    if self.hidden
      tests[18] = self.items.collect{ |i| i.hidden == self.hidden }.all?
      tests[19] = self.tax_items.collect{ |i| i.hidden == self.hidden }.all?
      tests[20] = self.payment_method_items.collect{ |i| i.hidden == self.hidden }.all?
    end    
    
    # finished orders have to have nr set
    if self.finished
      tests[21] = self.nr.nil? == false
    end

    0.upto(tests.size-1).each do |i|
      messages << "Order #{ self.id }: test#{i} failed." if tests[i] == false
    end
    return messages
  end
  
  def user_login
    if self.user
      return self.user.login if self.user
    else
      return self.customer.login if self.customer
    end
  end
end
