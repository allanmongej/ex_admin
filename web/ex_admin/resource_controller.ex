defmodule ExAdmin.ResourceController do
  @moduledoc false

  defmacro __using__(_opts) do
    quote do
      alias ExAdmin.Authorization
      import ExAdmin.Utils
      import ExAdmin.ParamsToAtoms

      def action(%{private: %{phoenix_action: action}} = conn, _options) do
        conn = conn |> assign(:xhr, get_req_header(conn, "x-requested-with") == ["XMLHttpRequest"])
        resource = @resource || conn.params["resource"]
        conn = scrub_params(conn, resource, action)
        defn = get_registered_by_controller_route!(conn, resource)
        params = filter_params(conn.params, defn.resource_model)

        if !restricted_action?(action, defn) do
          conn
          |> assign(:defn, defn)
          |> load_resource(action, defn, params[:id])
          |> authorize_action(action)
          |> handle_plugs(action, defn)
          |> handle_before_filter(action, defn, params)
          |> handle_custom_actions(action, defn, params)
        else
          render_403 conn
        end
      end

      defp do_form_view(conn, resource, params) do
        model = conn.assigns.defn.__struct__
        if function_exported? model, :form_view, 3 do
          apply(model, :form_view, [conn, resource, params])
        else
          ExAdmin.Form.default_form_view conn, resource, params
        end
      end

      defp handle_changeset_error(conn, defn, changeset, params) do
        conn = put_flash(conn, :inline_error, changeset|> Ecto.Changeset.traverse_errors(&translate_error/1) |> fix_inline_errors)
        |> Plug.Conn.assign(:changeset, changeset)
        |> Plug.Conn.assign(:ea_required, changeset.required)
        contents = do_form_view(conn, ExAdmin.Changeset.get_data(changeset), params)
        render(conn, "admin.html", html: contents, filters: nil)
      end

        @doc """
        Translates an error message using gettext.
        """
        def translate_error({msg, opts}) do
          # Because error messages were defined within Ecto, we must
          # call the Gettext module passing our Gettext backend. We
          # also use the "errors" domain as translations are placed
          # in the errors.po file.
          # Ecto will pass the :count keyword if the error message is
          # meant to be pluralized.
          # On your own code and templates, depending on whether you
          # need the message to be pluralized or not, this could be
          # written simply as:
          #
          #     dngettext "errors", "1 file", "%{count} files", count
          #     dgettext "errors", "is invalid"
          #
          if count = opts[:count] do
            Gettext.dngettext(ExAdmin.Gettext, "errors", msg, msg, count, opts)
          else
            Gettext.dgettext(ExAdmin.Gettext, "errors", msg, opts)
          end
        end

        def fix_inline_errors(errors) when is_map(errors) do
          errors
          |> Enum.map(fn{k, v} -> {k, fix_inline_errors(v)} end)
          |> Enum.into(%{})
        end

        def fix_inline_errors(errors) when is_list(errors) do
          Enum.join(errors, ", ")
        end

      defp render_403(conn) do
        conn
        |> put_layout(false)
        |> put_status(403)
        |> render(ExAdmin.ErrorView, "403.html")
        |> halt
      end

      defp restricted_action?(:destroy, defn), do: restricted_action?(:delete, defn)
      defp restricted_action?(:create, defn), do: restricted_action?(:new, defn)
      defp restricted_action?(:update, defn), do: restricted_action?(:edit, defn)
      defp restricted_action?(action, defn) do
        if action in [:show, :edit, :update, :new, :destroy, :delete] do
          not action in defn.actions
        else
          false
        end
      end

      def authorize_action(conn, action) do
        if ExAdmin.Authorization.authorize_action(conn.assigns[:resource], conn, action) do
          conn
        else
          render_403(conn)
        end
      end

      defp scrub_params(conn, required_key, action) when action in [:create, :update] do
        if conn.params[required_key] do
          Phoenix.Controller.scrub_params conn, required_key
        else
          conn
        end
      end
      defp scrub_params(conn, _required_key, _action), do: conn

      defp load_resource(conn, _action, defn, nil) do
        resource = defn.resource_model.__struct__
        assign(conn, :resource, resource)
      end
      defp load_resource(conn, action, defn, resource_id) do
        model = defn.__struct__
        query = model.run_query(repo(), defn, action, resource_id)
        resource =
        Authorization.authorize_query(defn.resource_model.__struct__, conn, query, action, resource_id)
        |> ExAdmin.Query.execute_query(repo(), action, resource_id)

        if resource == nil do
          raise Phoenix.Router.NoRouteError, conn: conn, router: __MODULE__
        end

        assign(conn, :resource, resource)
      end

      defp handle_custom_actions(%{halted: true} = conn, _, _, _), do: conn
      defp handle_custom_actions({conn, params}, action, defn, _) do
        handle_custom_actions(conn, action, defn, params)
      end
      defp handle_custom_actions(conn, :member, defn, params) do
        %{member_actions: member_actions} = defn
        action = String.to_atom params[:action]
        cond do
          member_action = Keyword.get(member_actions, action) ->
            member_action[:fun].(conn, params)
          true ->
            render_403 conn
        end
      end
      defp handle_custom_actions(conn, :collection, defn, params) do
        %{collection_actions: collection_actions} = defn
        action = String.to_atom params[:action]
        cond do
          collection_action = Keyword.get(collection_actions, action) ->
            collection_action[:fun].(conn, params)
          true ->
            render_403 conn
        end
      end

      defp handle_custom_actions(conn, action, defn, params) do
        apply(__MODULE__, action, [conn, defn, params])
      end

      defp handle_before_filter(%{halted: true} = conn, _, _, _), do: conn
      defp handle_before_filter(conn, action, defn, params) do
        _handle_before_filter(conn, action, defn, params, defn.controller_filters[:before_filter])
      end

      defp _handle_before_filter(conn, action, defn, params, [{name, opts} | t]) do
        filter = cond do
          opts[:only] ->
            if action in opts[:only], do: true, else: false
          opts[:except] ->
            if not action in opts[:except], do: true, else: false
          true -> true
        end
        if filter do
          apply(defn.__struct__, name, [conn, params])
        else
          conn
        end
        |> _handle_before_filter(action, defn, params, t)
      end
      defp _handle_before_filter(conn, _action, _defn, _params, _), do: conn

      defp handle_after_filter(conn, action, defn, params, resource) do
        _handle_after_filter({conn, params, resource}, action, defn, defn.controller_filters[:after_filter])
      end

      defp _handle_after_filter({conn, params, resource}, action, defn, [{name, opts} | t]) do
        filter = cond do
          opts[:only] ->
            if action in opts[:only], do: true, else: false
          opts[:except] ->
            if not action in opts[:except], do: true, else: false
          true -> true
        end
        if filter do
          case apply(defn.__struct__, name, [conn, params, resource, action]) do
            {_, _, _} = tuple -> tuple
            %Plug.Conn{} = conn -> {conn, params, resource}
            error ->
              raise ExAdmin.RuntimeError, message: (gettext "invalid after_filter return:") <> " #{inspect error}"
          end
        else
          {conn, params, resource}
        end
        |> _handle_after_filter(action, defn, t)
      end
      defp _handle_after_filter(args, _action, _defn, _), do: args

      defp handle_plugs(%{halted: true} = conn, _, _), do: conn
      defp handle_plugs(conn, :nested, _defn), do: conn
      defp handle_plugs(conn, _action, defn) do
        case Application.get_env(:ex_admin, :plug, []) do
          list when is_list(list) -> list
          item -> [{item, []}]
        end
        |> Keyword.merge(defn.plugs)
        |> Enum.reduce(conn, fn({name, opts}, conn) ->
          apply(name, :call, [conn, opts])
        end)
        |> authorized?
      end

      defp authorized?(%{assigns: %{authorized: true}} = conn), do: conn
      defp authorized?(%{assigns: %{authorized: false}}) do
        throw :unauthorized
      end
      defp authorized?(conn), do: conn

      defp repo, do: Application.get_env(:ex_admin, :repo)
    end
  end
end
