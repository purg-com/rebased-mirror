# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.ActivityPub.ActivityPubController do
  use Pleroma.Web, :controller

  alias Pleroma.Activity
  alias Pleroma.Delivery
  alias Pleroma.Object
  alias Pleroma.Object.Fetcher
  alias Pleroma.User
  alias Pleroma.Web.ActivityPub.ActivityPub
  alias Pleroma.Web.ActivityPub.InternalFetchActor
  alias Pleroma.Web.ActivityPub.ObjectView
  alias Pleroma.Web.ActivityPub.Relay
  alias Pleroma.Web.ActivityPub.UserView
  alias Pleroma.Web.ActivityPub.Utils
  alias Pleroma.Web.ActivityPub.Visibility
  alias Pleroma.Web.ControllerHelper
  alias Pleroma.Web.Endpoint
  alias Pleroma.Web.Federator
  alias Pleroma.Web.Plugs.EnsureAuthenticatedPlug
  alias Pleroma.Web.Plugs.FederatingPlug

  require Logger

  action_fallback(:errors)

  @federating_only_actions [:internal_fetch, :relay, :relay_following, :relay_followers]

  plug(FederatingPlug when action in @federating_only_actions)

  plug(
    EnsureAuthenticatedPlug,
    [unless_func: &FederatingPlug.federating?/1] when action not in @federating_only_actions
  )

  # Note: :following and :followers must be served even without authentication (as via :api)
  plug(
    EnsureAuthenticatedPlug
    when action in [:read_inbox, :whoami]
  )

  plug(
    Pleroma.Web.Plugs.Cache,
    [query_params: false, tracking_fun: &__MODULE__.track_object_fetch/2]
    when action in [:activity, :object]
  )

  plug(:set_requester_reachable when action in [:inbox])
  plug(:relay_active? when action in [:relay])

  defp relay_active?(conn, _) do
    if Pleroma.Config.get([:instance, :allow_relay]) do
      conn
    else
      conn
      |> render_error(:not_found, "not found")
      |> halt()
    end
  end

  def user(conn, %{"nickname" => nickname}) do
    with %User{local: true} = user <- User.get_cached_by_nickname(nickname) do
      conn
      |> put_resp_content_type("application/activity+json")
      |> put_view(UserView)
      |> render("user.json", %{user: user})
    else
      nil -> {:error, :not_found}
      %{local: false} -> {:error, :not_found}
    end
  end

  def object(%{assigns: assigns} = conn, _) do
    with ap_id <- Endpoint.url() <> conn.request_path,
         %Object{} = object <- Object.get_cached_by_ap_id(ap_id),
         user <- Map.get(assigns, :user, nil),
         {_, true} <- {:visible?, Visibility.visible_for_user?(object, user)} do
      conn
      |> maybe_skip_cache(user)
      |> assign(:tracking_fun_data, object.id)
      |> set_cache_ttl_for(object)
      |> put_resp_content_type("application/activity+json")
      |> put_view(ObjectView)
      |> render("object.json", object: object)
    else
      {:visible?, false} -> {:error, :not_found}
      nil -> {:error, :not_found}
    end
  end

  def track_object_fetch(conn, nil), do: conn

  def track_object_fetch(conn, object_id) do
    with %{assigns: %{user: %User{id: user_id}}} <- conn do
      Delivery.create(object_id, user_id)
    end

    conn
  end

  def activity(%{assigns: assigns} = conn, _) do
    with ap_id <- Endpoint.url() <> conn.request_path,
         %Activity{} = activity <- Activity.normalize(ap_id),
         {_, true} <- {:local?, activity.local},
         user <- Map.get(assigns, :user, nil),
         {_, true} <- {:visible?, Visibility.visible_for_user?(activity, user)} do
      conn
      |> maybe_skip_cache(user)
      |> maybe_set_tracking_data(activity)
      |> set_cache_ttl_for(activity)
      |> put_resp_content_type("application/activity+json")
      |> put_view(ObjectView)
      |> render("object.json", object: activity)
    else
      {:visible?, false} -> {:error, :not_found}
      {:local?, false} -> {:error, :not_found}
      nil -> {:error, :not_found}
    end
  end

  defp maybe_set_tracking_data(conn, %Activity{data: %{"type" => "Create"}} = activity) do
    object_id = Object.normalize(activity, fetch: false).id
    assign(conn, :tracking_fun_data, object_id)
  end

  defp maybe_set_tracking_data(conn, _activity), do: conn

  defp set_cache_ttl_for(conn, %Activity{object: object}) do
    set_cache_ttl_for(conn, object)
  end

  defp set_cache_ttl_for(conn, entity) do
    ttl =
      case entity do
        %Object{data: %{"type" => "Question"}} ->
          Pleroma.Config.get([:web_cache_ttl, :activity_pub_question])

        %Object{} ->
          Pleroma.Config.get([:web_cache_ttl, :activity_pub])

        _ ->
          nil
      end

    assign(conn, :cache_ttl, ttl)
  end

  def maybe_skip_cache(conn, user) do
    if user do
      conn
      |> assign(:skip_cache, true)
    else
      conn
    end
  end

  # GET /relay/following
  def relay_following(conn, _params) do
    with %{halted: false} = conn <- FederatingPlug.call(conn, []) do
      conn
      |> put_resp_content_type("application/activity+json")
      |> put_view(UserView)
      |> render("following.json", %{user: Relay.get_actor()})
    end
  end

  def following(%{assigns: %{user: for_user}} = conn, %{"nickname" => nickname, "page" => page}) do
    with %User{} = user <- User.get_cached_by_nickname(nickname),
         {:show_follows, true} <-
           {:show_follows, (for_user && for_user == user) || !user.hide_follows} do
      {page, _} = Integer.parse(page)

      conn
      |> put_resp_content_type("application/activity+json")
      |> put_view(UserView)
      |> render("following.json", %{user: user, page: page, for: for_user})
    else
      {:show_follows, _} ->
        conn
        |> put_resp_content_type("application/activity+json")
        |> send_resp(403, "")
    end
  end

  def following(%{assigns: %{user: for_user}} = conn, %{"nickname" => nickname}) do
    with %User{} = user <- User.get_cached_by_nickname(nickname) do
      conn
      |> put_resp_content_type("application/activity+json")
      |> put_view(UserView)
      |> render("following.json", %{user: user, for: for_user})
    end
  end

  # GET /relay/followers
  def relay_followers(conn, _params) do
    with %{halted: false} = conn <- FederatingPlug.call(conn, []) do
      conn
      |> put_resp_content_type("application/activity+json")
      |> put_view(UserView)
      |> render("followers.json", %{user: Relay.get_actor()})
    end
  end

  def followers(%{assigns: %{user: for_user}} = conn, %{"nickname" => nickname, "page" => page}) do
    with %User{} = user <- User.get_cached_by_nickname(nickname),
         {:show_followers, true} <-
           {:show_followers, (for_user && for_user == user) || !user.hide_followers} do
      {page, _} = Integer.parse(page)

      conn
      |> put_resp_content_type("application/activity+json")
      |> put_view(UserView)
      |> render("followers.json", %{user: user, page: page, for: for_user})
    else
      {:show_followers, _} ->
        conn
        |> put_resp_content_type("application/activity+json")
        |> send_resp(403, "")
    end
  end

  def followers(%{assigns: %{user: for_user}} = conn, %{"nickname" => nickname}) do
    with %User{} = user <- User.get_cached_by_nickname(nickname) do
      conn
      |> put_resp_content_type("application/activity+json")
      |> put_view(UserView)
      |> render("followers.json", %{user: user, for: for_user})
    end
  end

  def outbox(
        %{assigns: %{user: for_user}} = conn,
        %{"nickname" => nickname, "page" => page?} = params
      )
      when page? in [true, "true"] do
    with %User{} = user <- User.get_cached_by_nickname(nickname) do
      # "include_poll_votes" is a hack because postgres generates inefficient
      # queries when filtering by 'Answer', poll votes will be hidden by the
      # visibility filter in this case anyway
      params =
        params
        |> Map.drop(["nickname", "page"])
        |> Map.put("include_poll_votes", true)
        |> Map.new(fn {k, v} -> {String.to_existing_atom(k), v} end)

      activities = ActivityPub.fetch_user_activities(user, for_user, params)

      conn
      |> put_resp_content_type("application/activity+json")
      |> put_view(UserView)
      |> render("activity_collection_page.json", %{
        activities: activities,
        pagination: ControllerHelper.get_pagination_fields(conn, activities),
        iri: "#{user.ap_id}/outbox"
      })
    end
  end

  def outbox(conn, %{"nickname" => nickname}) do
    with %User{} = user <- User.get_cached_by_nickname(nickname) do
      conn
      |> put_resp_content_type("application/activity+json")
      |> put_view(UserView)
      |> render("activity_collection.json", %{iri: "#{user.ap_id}/outbox"})
    end
  end

  def inbox(%{assigns: %{valid_signature: true}} = conn, %{"nickname" => nickname} = params) do
    with %User{} = recipient <- User.get_cached_by_nickname(nickname),
         {:ok, %User{} = actor} <- User.get_or_fetch_by_ap_id(params["actor"]),
         true <- Utils.recipient_in_message(recipient, actor, params),
         params <- Utils.maybe_splice_recipient(recipient.ap_id, params) do
      Federator.incoming_ap_doc(params)
      json(conn, "ok")
    end
  end

  def inbox(%{assigns: %{valid_signature: true}} = conn, params) do
    Federator.incoming_ap_doc(params)
    json(conn, "ok")
  end

  def inbox(%{assigns: %{valid_signature: false}} = conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json("Invalid HTTP Signature")
  end

  # POST /relay/inbox -or- POST /internal/fetch/inbox
  def inbox(conn, %{"type" => "Create"} = params) do
    if FederatingPlug.federating?() do
      post_inbox_relayed_create(conn, params)
    else
      conn
      |> put_status(:bad_request)
      |> json("Not federating")
    end
  end

  def inbox(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json("error, missing HTTP Signature")
  end

  defp post_inbox_relayed_create(conn, params) do
    Logger.debug(
      "Signature missing or not from author, relayed Create message, fetching object from source"
    )

    Fetcher.fetch_object_from_id(params["object"]["id"])

    json(conn, "ok")
  end

  defp represent_service_actor(%User{} = user, conn) do
    conn
    |> put_resp_content_type("application/activity+json")
    |> put_view(UserView)
    |> render("user.json", %{user: user})
  end

  defp represent_service_actor(nil, _), do: {:error, :not_found}

  def relay(conn, _params) do
    Relay.get_actor()
    |> represent_service_actor(conn)
  end

  def internal_fetch(%Plug.Conn{host: host} = conn, _params) do
    with fetch_actor_origin when is_binary(fetch_actor_origin) <-
           Pleroma.Config.get([:activitypub, :fetch_actor_origin]),
         %URI{host: fetch_actor_host} <- URI.parse(fetch_actor_origin),
         true <- host == fetch_actor_host do
      fetch_actor_origin
    else
      _ -> Pleroma.Web.Endpoint.url()
    end
    |> InternalFetchActor.get_actor()
    |> represent_service_actor(conn)
  end

  @doc "Returns the authenticated user's ActivityPub User object or a 404 Not Found if non-authenticated"
  def whoami(%{assigns: %{user: %User{} = user}} = conn, _params) do
    conn
    |> put_resp_content_type("application/activity+json")
    |> put_view(UserView)
    |> render("user.json", %{user: user})
  end

  def read_inbox(
        %{assigns: %{user: %User{nickname: nickname} = user}} = conn,
        %{"nickname" => nickname, "page" => page?} = params
      )
      when page? in [true, "true"] do
    params =
      params
      |> Map.drop(["nickname", "page"])
      |> Map.put("blocking_user", user)
      |> Map.put("user", user)
      |> Map.new(fn {k, v} -> {String.to_existing_atom(k), v} end)

    activities =
      [user.ap_id | User.following(user)]
      |> ActivityPub.fetch_activities(params)
      |> Enum.reverse()

    conn
    |> put_resp_content_type("application/activity+json")
    |> put_view(UserView)
    |> render("activity_collection_page.json", %{
      activities: activities,
      pagination: ControllerHelper.get_pagination_fields(conn, activities),
      iri: "#{user.ap_id}/inbox"
    })
  end

  def read_inbox(%{assigns: %{user: %User{nickname: nickname} = user}} = conn, %{
        "nickname" => nickname
      }) do
    conn
    |> put_resp_content_type("application/activity+json")
    |> put_view(UserView)
    |> render("activity_collection.json", %{iri: "#{user.ap_id}/inbox"})
  end

  def read_inbox(%{assigns: %{user: %User{nickname: as_nickname}}} = conn, %{
        "nickname" => nickname
      }) do
    err =
      dgettext("errors", "can't read inbox of %{nickname} as %{as_nickname}",
        nickname: nickname,
        as_nickname: as_nickname
      )

    conn
    |> put_status(:forbidden)
    |> json(err)
  end

  defp errors(conn, {:error, :not_found}) do
    conn
    |> put_status(:not_found)
    |> json(dgettext("errors", "Not found"))
  end

  defp errors(conn, _e) do
    conn
    |> put_status(:internal_server_error)
    |> json(dgettext("errors", "error"))
  end

  defp set_requester_reachable(%Plug.Conn{} = conn, _) do
    with actor <- conn.params["actor"],
         true <- is_binary(actor) do
      Pleroma.Instances.set_reachable(actor)
    end

    conn
  end

  def pinned(conn, %{"nickname" => nickname}) do
    with %User{} = user <- User.get_cached_by_nickname(nickname) do
      conn
      |> put_resp_header("content-type", "application/activity+json")
      |> json(UserView.render("featured.json", %{user: user}))
    end
  end
end
