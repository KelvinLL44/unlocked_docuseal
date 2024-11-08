# frozen_string_literal: true

module Api
  class TemplatesController < ApiBaseController
    load_and_authorize_resource :template

    def index
      templates = filter_templates(@templates, params)

      templates = paginate(templates.preload(:author, :folder))

      schema_documents =
        ActiveStorage::Attachment.where(record_id: templates.map(&:id),
                                        record_type: 'Template',
                                        name: :documents,
                                        uuid: templates.flat_map { |t| t.schema.pluck('attachment_uuid') })
                                 .preload(:blob)

      preview_image_attachments =
        ActiveStorage::Attachment.joins(:blob)
                                 .where(blob: { filename: ['0.png', '0.jpg'] })
                                 .where(record_id: schema_documents.map(&:id),
                                        record_type: 'ActiveStorage::Attachment',
                                        name: :preview_images)
                                 .preload(:blob)

      render json: {
        data: templates.map do |t|
          Templates::SerializeForApi.call(
            t,
            schema_documents.select { |e| e.record_id == t.id },
            preview_image_attachments
          )
        end,
        pagination: {
          count: templates.size,
          next: templates.last&.id,
          prev: templates.first&.id
        }
      }
    end

    def show
      render json: Templates::SerializeForApi.call(@template)
    end

    # kelvin's !!
    def create
      Rails.logger.info "[Kelvin's debug] Incoming Params: #{params.inspect}"
      
      url_params = create_file_params_from_url if params[:url].present?

      Rails.logger.info "[Kelvin's debug] URL Params: #{url_params.inspect}"

      save_template!(@template, url_params)

      Rails.logger.info "[Kelvin's debug] here 1"

      documents = Templates::CreateAttachments.call(@template, url_params || params, extract_fields: true)
      Rails.logger.info "[Kelvin's debug] here 2"
      schema = documents.map { |doc| { attachment_uuid: doc.uuid, name: doc.filename.base } }
      Rails.logger.info "[Kelvin's debug] here 3"
      if @template.fields.blank?
        @template.fields = Templates::ProcessDocument.normalize_attachment_fields(@template, documents)

        schema.each { |item| item['pending_fields'] = true } if @template.fields.present?
      end

      Rails.logger.info "[Kelvin's debug] here 4"
      @template.update!(schema:)
      Rails.logger.info "[Kelvin's debug] here 5"
      # enqueue_template_created_webhooks(@template)  # not working for now 
      Rails.logger.info "[Kelvin's debug] here 6"
      render json: { message: "Kelvin's API on Ruby: Template created successfully", template: @template.as_json(only: [:id, :name, :created_at]) }, status: :created
    rescue Templates::CreateAttachments::PdfEncrypted
      render json: { error: "PDF is encrypted and requires a password." }, status: :unprocessable_entity
    rescue StandardError => e
      Rollbar.error(e) if defined?(Rollbar)

      render json: { error: "Unable to create template. Please try again later." }, status: :internal_server_error
    end

    def update
      if (folder_name = params[:folder_name] || params.dig(:template, :folder_name))
        @template.folder = TemplateFolders.find_or_create_by_name(current_user, folder_name)
      end

      Array.wrap(params[:roles].presence || params.dig(:template, :roles).presence).each_with_index do |role, index|
        if (item = @template.submitters[index])
          item['name'] = role
        else
          @template.submitters << { 'name' => role, 'uuid' => SecureRandom.uuid }
        end
      end

      archived = params.key?(:archived) ? params[:archived] : params.dig(:template, :archived)

      if archived.in?([true, false])
        @template.archived_at = archived == true ? Time.current : nil
      end

      @template.update!(template_params)

      WebhookUrls.for_account_id(@template.account_id, 'template.updated').each do |webhook_url|
        SendTemplateUpdatedWebhookRequestJob.perform_async('template_id' => @template.id,
                                                           'webhook_url_id' => webhook_url.id)
      end

      render json: @template.as_json(only: %i[id updated_at])
    end

    def destroy
      if params[:permanently] == 'true'
        @template.destroy!
      else
        @template.update!(archived_at: Time.current)
      end

      render json: @template.as_json(only: %i[id archived_at])
    end

    private

    def filter_templates(templates, params)
      templates = Templates.search(templates, params[:q])
      templates = params[:archived] ? templates.archived : templates.active
      templates = templates.where(external_id: params[:application_key]) if params[:application_key].present?
      templates = templates.where(external_id: params[:external_id]) if params[:external_id].present?
      templates = templates.joins(:folder).where(folder: { name: params[:folder] }) if params[:folder].present?

      templates
    end

    def template_params
      permitted_params = [
        :name,
        :external_id,
        {
          submitters: [%i[name uuid is_requester invite_by_uuid linked_to_uuid email]],
          fields: [[:uuid, :submitter_uuid, :name, :type,
                    :required, :readonly, :default_value,
                    :title, :description,
                    { preferences: {},
                      conditions: [%i[field_uuid value action]],
                      options: [%i[value uuid]],
                      validation: %i[message pattern],
                      areas: [%i[x y w h cell_w attachment_uuid option_uuid page]] }]]
        }
      ]

      if params.key?(:template)
        params.require(:template).permit(permitted_params)
      else
        params.permit(permitted_params)
      end
    end
    
    # Add the helper methods
    def save_template!(template, url_params)
      template.account = current_account
      template.author = current_user
      template.folder = TemplateFolders.find_or_create_by_name(current_user, params[:folder_name])
      template.name = File.basename((url_params || params)[:files].first.original_filename, '.*')

      template.save!

      template
    end

    def create_file_params_from_url
      tempfile = Tempfile.new
      tempfile.binmode
      tempfile.write(DownloadUtils.call(params[:url]).body)
      tempfile.rewind
      

      file = ActionDispatch::Http::UploadedFile.new(
        tempfile: tempfile,
        filename: File.basename(
          URI.decode_www_form_component(params[:filename].presence || params[:url]), '.*'
        ),
        type: Marcel::MimeType.for(tempfile)
      )

      { files: [file] }
    end

    def enqueue_template_created_webhooks(template)
      WebhookUrls.for_account_id(template.account_id, 'template.created').each do |webhook_url|
        SendTemplateCreatedWebhookRequestJob.perform_async('template_id' => template.id,
                                                           'webhook_url_id' => webhook_url.id)
      end
    end
  end
end
